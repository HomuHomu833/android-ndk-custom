/* portable_echo.c - A portable recreation of GNU echo
   Public domain / CC0 – no warranty. */

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
   bool flag_no_newline = false;

   /* Discard the name of the executable. */
   if (argc > 0) {
      argc--;
      argv++;
   }

   /* echo should only accept -n as a first option, everything
      else must be treated as part of the input string. */
   if (argc > 0 && strcmp(argv[0], "-n") == 0) {
      flag_no_newline = true;
      argc--;
      argv++;
   }

   for (int i = 0; i < argc; ++i)
      printf("%s%s", (i > 0) ? " " : "", argv[i]);

   if (!flag_no_newline)
      printf("\n");

   return 0;
}
