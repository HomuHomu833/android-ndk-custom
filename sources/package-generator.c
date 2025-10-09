#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char *argv[]) {
   if (argc != 3) {
      fprintf(stderr, "Usage: %s <package.xml> <release>\n", argv[0]);
      return 1;
   }

   const char *filepath = argv[1];
   char release[100];
   strcpy(release, argv[2]);

   int is_beta = strstr(release, "-beta") != NULL;

   int major = 0, minor = 0, micro = 0, preview = 0;

   // extract preview number first (if beta)
   if (is_beta) {
      char *beta_ptr = strstr(release, "-beta");
      sscanf(beta_ptr, "-beta%d", &preview);
      *beta_ptr = '\0'; // cut off "-beta..."
   }

   // parse version numbers
   sscanf(release, "%d.%d.%d", &major, &minor, &micro);

   FILE *f = fopen(filepath, "w");
   if (!f) {
      perror("Error opening output file");
      return 1;
   }

   fprintf(
       f,
       "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
       "<ns2:repository\n"
       "\txmlns:ns2=\"http://schemas.android.com/repository/android/common/"
       "02\"\n"
       "\txmlns:ns3=\"http://schemas.android.com/repository/android/common/"
       "01\"\n"
       "\txmlns:ns4=\"http://schemas.android.com/repository/android/generic/"
       "01\"\n"
       "\txmlns:ns5=\"http://schemas.android.com/repository/android/generic/"
       "02\"\n"
       "\txmlns:ns6=\"http://schemas.android.com/sdk/android/repo/addon2/01\"\n"
       "\txmlns:ns7=\"http://schemas.android.com/sdk/android/repo/addon2/02\"\n"
       "\txmlns:ns8=\"http://schemas.android.com/sdk/android/repo/addon2/03\"\n"
       "\txmlns:ns9=\"http://schemas.android.com/sdk/android/repo/repository2/"
       "01\"\n"
       "\txmlns:ns10=\"http://schemas.android.com/sdk/android/repo/repository2/"
       "02\"\n"
       "\txmlns:ns11=\"http://schemas.android.com/sdk/android/repo/repository2/"
       "03\"\n"
       "\txmlns:ns12=\"http://schemas.android.com/sdk/android/repo/sys-img2/"
       "04\"\n"
       "\txmlns:ns13=\"http://schemas.android.com/sdk/android/repo/sys-img2/"
       "03\"\n"
       "\txmlns:ns14=\"http://schemas.android.com/sdk/android/repo/sys-img2/"
       "02\"\n"
       "\txmlns:ns15=\"http://schemas.android.com/sdk/android/repo/sys-img2/"
       "01\">\n");

   if (is_beta) {
      fprintf(f,
              "\t<license id=\"android-sdk-preview-license\" "
              "type=\"text\">free to use</license>\n"
              "\t<localPackage path=\"ndk;%d.%d.%d\" obsolete=\"false\">\n"
              "\t\t<type-details\n"
              "\t\t\txmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" "
              "xsi:type=\"ns5:genericDetailsType\"/>\n"
              "\t\t\t<revision>\n"
              "\t\t\t\t<major>%d</major>\n"
              "\t\t\t\t<minor>%d</minor>\n"
              "\t\t\t\t<micro>%d</micro>\n"
              "\t\t\t\t<preview>%d</preview>\n"
              "\t\t\t</revision>\n"
              "\t\t\t<display-name>NDK (Side by side) %d.%d.%d</display-name>\n"
              "\t\t\t<uses-license ref=\"android-sdk-preview-license\"/>\n"
              "\t</localPackage>\n"
              "</ns2:repository>\n",
              major, minor, micro, major, minor, micro, preview, major, minor,
              micro);
   } else {
      fprintf(f,
              "\t<license id=\"android-sdk-license\" type=\"text\">free to "
              "use</license>\n"
              "\t<localPackage path=\"ndk;%d.%d.%d\" obsolete=\"false\">\n"
              "\t\t<type-details\n"
              "\t\t\txmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" "
              "xsi:type=\"ns5:genericDetailsType\"/>\n"
              "\t\t\t<revision>\n"
              "\t\t\t\t<major>%d</major>\n"
              "\t\t\t\t<minor>%d</minor>\n"
              "\t\t\t\t<micro>%d</micro>\n"
              "\t\t\t</revision>\n"
              "\t\t\t<display-name>NDK (Side by side) %d.%d.%d</display-name>\n"
              "\t\t\t<uses-license ref=\"android-sdk-license\"/>\n"
              "\t</localPackage>\n"
              "</ns2:repository>\n",
              major, minor, micro, major, minor, micro, major, minor, micro);
   }

   fclose(f);
   return 0;
}
