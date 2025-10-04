/* portable_cmp.c - A portable recreation of GNU cmp
   Public domain / CC0 – no warranty. */

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BUF_SIZE 8192
#define VERSION "1.0"

static const char *print_char(unsigned char c) {
   static char buf[3];

   if (c >= 32 && c <= 126) {
      buf[0] = c;
      buf[1] = '\0';
   } else if (c == 127) {
      strcpy(buf, "^?");
   } else {
      buf[0] = '^';
      buf[1] = c + '@';
      buf[2] = '\0';
   }

   return buf;
}

static long long parse_size(const char *arg) {
   char *end;
   long long val = strtoll(arg, &end, 10);
   if (*end) {
      if (*end == 'K' || *end == 'k')
         val *= 1024LL;
      else if (*end == 'M' || *end == 'm')
         val *= 1024LL * 1024;
      else if (*end == 'G' || *end == 'g')
         val *= 1024LL * 1024 * 1024;
      else {
         fprintf(stderr, "cmp: invalid size suffix in '%s'\n", arg);
         exit(2);
      }
   }
   return val;
}

static void usage(const char *prog) {
   fprintf(
       stderr,
       "\033[1mUsage:\033[0m %s [OPTIONS] FILE1 FILE2\n"
       "Compare two files byte by byte.\n\n"

       "\033[1mOptions:\033[0m\n"
       "  \033[32m-b, --print-bytes\033[0m            Print differing bytes.\n"
       "  \033[32m-i SKIP\033[0m                      Skip SKIP bytes at start "
       "of both files.\n"
       "  \033[32m--ignore-initial=SKIP1:SKIP2\033[0m Skip different initial "
       "bytes for each file.\n"
       "  \033[32m-l\033[0m                           Print all differing byte "
       "positions.\n"
       "  \033[32m-n LIMIT\033[0m                     Compare at most LIMIT "
       "bytes.\n"
       "  \033[32m-s\033[0m                           Silent mode; only return "
       "status.\n"
       "  \033[32m--help\033[0m                       Display this help and "
       "exit.\n"
       "  \033[32m--version\033[0m                    Output version "
       "information and exit.\n",
       prog);
   exit(2);
}

int main(int argc, char **argv) {
   bool opt_print_bytes = false;
   bool opt_verbose = false;
   bool opt_silent = false;
   long long skip1 = 0, skip2 = 0;
   long long limit = LLONG_MAX;

   const char *file1 = NULL, *file2 = NULL;

   for (int i = 1; i < argc; i++) {
      if (strcmp(argv[i], "--") == 0) {
         // stop option parsing
         i++;
         if (i < argc) file1 = argv[i++];
         if (i < argc) file2 = argv[i++];
         break;
      } else if (argv[i][0] == '-') {
         if (strcmp(argv[i], "-b") == 0 ||
             strcmp(argv[i], "--print-bytes") == 0) {
            opt_print_bytes = true;
         } else if (strcmp(argv[i], "-l") == 0) {
            opt_verbose = true;
         } else if (strcmp(argv[i], "-s") == 0) {
            opt_silent = true;
         } else if (strcmp(argv[i], "-i") == 0) {
            if (++i >= argc) usage(argv[0]);
            skip1 = skip2 = parse_size(argv[i]);
         } else if (strncmp(argv[i], "--ignore-initial=", 17) == 0) {
            char *arg = argv[i] + 17;
            char *colon = strchr(arg, ':');
            if (colon) {
               *colon = '\0';
               skip1 = parse_size(arg);
               skip2 = parse_size(colon + 1);
            } else {
               skip1 = skip2 = parse_size(arg);
            }
         } else if (strcmp(argv[i], "-n") == 0) {
            if (++i >= argc) usage(argv[0]);
            limit = parse_size(argv[i]);
         } else if (strcmp(argv[i], "--help") == 0 ||
                    strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
         } else if (strcmp(argv[i], "--version") == 0 ||
                    strcmp(argv[i], "-v") == 0) {
            printf("cmp (portable) %s\n", VERSION);
            printf("Written by HomuHomu833.\n\n");
            printf(
                "This is free software: you are free to change and "
                "redistribute it.\n");
            printf("Released into the public domain / CC0 – no warranty.\n");
            return 0;
         } else {
            usage(argv[0]);
         }
      } else {
         // treat as file argument
         if (!file1)
            file1 = argv[i];
         else if (!file2)
            file2 = argv[i];
         else
            usage(argv[0]);  // too many files
      }
   }

   if (!file1 || !file2) usage(argv[0]);

   FILE *f1 = strcmp(file1, "-") == 0 ? stdin : fopen(file1, "rb");
   FILE *f2 = strcmp(file2, "-") == 0 ? stdin : fopen(file2, "rb");
   if (!f1) {
      fprintf(stderr, "cmp: %s: %s\n", file1, strerror(errno));
      return 2;
   }
   if (!f2) {
      fprintf(stderr, "cmp: %s: %s\n", file2, strerror(errno));
      return 2;
   }

   // skip initial bytes
   if (skip1 > 0) fseek(f1, skip1, SEEK_SET);
   if (skip2 > 0) fseek(f2, skip2, SEEK_SET);

   unsigned char buf1[BUF_SIZE], buf2[BUF_SIZE];
   long long pos = 1, line = 1;
   int status = 0;

   while (limit > 0) {
      size_t toread = (limit > BUF_SIZE ? BUF_SIZE : (size_t)limit);
      size_t n1 = fread(buf1, 1, toread, f1);
      size_t n2 = fread(buf2, 1, toread, f2);
      size_t n = n1 < n2 ? n1 : n2;

      for (size_t j = 0; j < n; j++, pos++) {
         if (buf1[j] == '\n' && buf2[j] == '\n') line++;
         if (buf1[j] != buf2[j]) {
            status = 1;
            if (opt_silent) {
               fclose(f1);
               fclose(f2);
               return 1;
            }
            if (opt_verbose) {
               printf("%7lld %3o %3o\n", pos, buf1[j], buf2[j]);
            } else if (opt_print_bytes) {
               char p1[4], p2[4];

               snprintf(p1, sizeof(p1), "%s", print_char(buf1[j]));
               snprintf(p2, sizeof(p2), "%s", print_char(buf2[j]));

               printf("%s %s differ: byte %lld, line %lld is %3o %s %3o %s\n",
                      file1, file2, pos, line, buf1[j], p1, buf2[j], p2);

               fclose(f1);
               fclose(f2);
               return 1;
            } else {
               printf("%s %s differ: char %lld, line %lld\n", file1, file2, pos,
                      line);
               fclose(f1);
               fclose(f2);
               return 1;
            }
         }
      }

      if (n1 != n2) {
         status = 1;
         if (!opt_silent) {
            fprintf(stderr, "cmp: EOF on ‘%s’ after byte %lld\n",
                    (n1 < n2 ? file1 : file2), pos - 1);
         }
         break;
      }

      if (n1 == 0 || n2 == 0) break;

      limit -= n;
   }

   fclose(f1);
   fclose(f2);
   return status;
}