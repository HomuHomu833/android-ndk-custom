/* portable_echo.c - A portable recreation of GNU echo
   Public domain / CC0 – no warranty. */

#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int hextobin(unsigned char c) {
   if (c >= '0' && c <= '9')
      return c - '0';
   if (c >= 'a' && c <= 'f')
      return 10 + (c - 'a');
   if (c >= 'A' && c <= 'F')
      return 10 + (c - 'A');
   return -1;
}

int main(int argc, char **argv) {
   bool display_newline = true;
   bool interpret_escapes = false;

   // skip program name
   argc--;
   argv++;

   // option parsing
   while (argc > 0 && argv[0][0] == '-') {
      if (strcmp(argv[0], "-n") == 0) {
         display_newline = false;
      } else if (strcmp(argv[0], "-e") == 0) {
         interpret_escapes = true;
      } else if (strcmp(argv[0], "-E") == 0) {
         interpret_escapes = false;
      } else {
         break; // treat as normal string
      }
      argc--;
      argv++;
   }

   // print arguments
   for (int i = 0; i < argc; i++) {
      const char *s = argv[i];
      while (*s) {
         unsigned char c = *s++;
         if (interpret_escapes && c == '\\' && *s) {
            switch (*s) {
            case 'a':
               putchar('\a');
               s++;
               continue;
            case 'b':
               putchar('\b');
               s++;
               continue;
            case 'c':
               return 0; // stop immediately
            case 'e':
               putchar(27);
               s++;
               continue;
            case 'f':
               putchar('\f');
               s++;
               continue;
            case 'n':
               putchar('\n');
               s++;
               continue;
            case 'r':
               putchar('\r');
               s++;
               continue;
            case 't':
               putchar('\t');
               s++;
               continue;
            case 'v':
               putchar('\v');
               s++;
               continue;
            case '\\':
               putchar('\\');
               s++;
               continue;
            case 'x': {
               s++;
               int v = hextobin(*s);
               if (v >= 0) {
                  s++;
                  int v2 = hextobin(*s);
                  if (v2 >= 0) {
                     v = v * 16 + v2;
                     s++;
                  }
                  putchar(v);
                  continue;
               }
               putchar('x');
               continue;
            }
            case '0': {
               int v = 0, count = 0;
               while (count < 3 && *s >= '0' && *s <= '7') {
                  v = v * 8 + (*s - '0');
                  s++;
                  count++;
               }
               putchar(v);
               continue;
            }
            default:
               putchar('\\'); // print literally
               continue;
            }
         }
         putchar(c);
      }
      if (i < argc - 1)
         putchar(' ');
   }

   if (display_newline)
      putchar('\n');
   return 0;
}