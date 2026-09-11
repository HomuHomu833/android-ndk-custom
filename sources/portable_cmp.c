/* portable_cmp.c - A portable recreation of GNU cmp
   Public domain / CC0 – no warranty. */

#include <stdio.h>
#include <string.h>

#define BUF_SIZE 4096 /* Google cmp_win.c BUFSIZE */

static int usage(void) {
   printf("Usage: cmp [-s] file1 file2\n");
   return 1;
}

static int cant_open(const char *path) {
   printf("ERROR: can't open file %s\n", path);
   return 1;
}

/* glibc lets fopen() succeed on a directory and fails at the first read.
   Google's Windows build refuses to open one, so probe and match it. */
static FILE *open_file(const char *path) {
   FILE *f = fopen(path, "rb");

   if (!f)
      return NULL;

   if (fgetc(f) == EOF && ferror(f)) {
      fclose(f);
      return NULL;
   }

   rewind(f); /* also clears the error indicator */
   return f;
}

int main(int argc, char **argv) {
   const char *file1;
   const char *file2;

   if (argc == 4 && strcmp(argv[1], "-s") == 0) {
      file1 = argv[2];
      file2 = argv[3];
   } else if (argc == 3) {
      file1 = argv[1];
      file2 = argv[2];
   } else {
      return usage();
   }

   FILE *f1 = open_file(file1);
   if (!f1)
      return cant_open(file1);

   FILE *f2 = open_file(file2);
   if (!f2) {
      fclose(f1);
      return cant_open(file2);
   }

   char buf1[BUF_SIZE];
   char buf2[BUF_SIZE];

   size_t n1 = 0;
   size_t n2 = 0;
   int ret = 0;

   /* A short read only happens at EOF, so equal-length files stay in lockstep
      and n1 != n2 is exactly the length mismatch. */
   do {
      n1 = fread(buf1, 1, BUF_SIZE, f1);
      n2 = fread(buf2, 1, BUF_SIZE, f2);
      ret = (n1 != n2) || memcmp(buf1, buf2, n1) != 0;
   } while (!ret && n1 == BUF_SIZE);

   fclose(f1);
   fclose(f2);
   return ret;
}
