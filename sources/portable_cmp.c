/* portable_cmp.c - A portable recreation of GNU cmp
   Public domain / CC0 – no warranty. */

#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BUF_SIZE 8192
#define VERSION "1.1"

static void visible_byte(unsigned char c, char *out) {
    if (c <= 31) {
        out[0] = '^';
        out[1] = c + 64;
        out[2] = '\0';
    } else if (c <= 126) {
        out[0] = c;
        out[1] = '\0';
    } else if (c == 127) {
        strcpy(out, "^?");
    } else if (c <= 159) {
        sprintf(out, "M-^%c", c - 64);
    } else if (c <= 254) {
        sprintf(out, "M-%c", c - 128);
    } else {
        strcpy(out, "M-^?");
    }
}

static long long parse_size(const char *arg) {
    char *end;
    long long val = strtoll(arg, &end, 10);

    if (*end) {
        if (strcmp(end, "kB") == 0)
            val *= 1000LL;
        else if (strcmp(end, "K") == 0)
            val *= 1024LL;
        else if (strcmp(end, "MB") == 0)
            val *= 1000000LL;
        else if (strcmp(end, "M") == 0)
            val *= 1024LL * 1024;
        else if (strcmp(end, "GB") == 0)
            val *= 1000000000LL;
        else if (strcmp(end, "G") == 0)
            val *= 1024LL * 1024 * 1024;
        else {
            fprintf(stderr,
                    "cmp: invalid size suffix in '%s'\n",
                    arg);
            exit(2);
        }
    }

    return val;
}

static void skip_bytes(FILE *f, long long n) {
    unsigned char buf[4096];

    while (n > 0) {
        size_t chunk =
            n > sizeof(buf) ? sizeof(buf) : (size_t)n;

        size_t r = fread(buf, 1, chunk, f);

        if (r == 0)
            break;

        n -= r;
    }
}

static void usage(const char *prog) {
    fprintf(stderr,
            "Usage: %s [OPTIONS] FILE1 FILE2\n"
            "Compare two files byte by byte.\n\n"
            "Options:\n"
            "  -b        Print differing bytes\n"
            "  -l        Verbose output\n"
            "  -s        Silent mode\n"
            "  -i SKIP   Skip bytes at start\n"
            "  -n LIMIT  Compare at most LIMIT bytes\n"
            "  --help    Show help\n"
            "  --version Show version\n",
            prog);
    exit(2);
}

int main(int argc, char **argv) {

    bool opt_print_bytes = false;
    bool opt_verbose = false;
    bool opt_silent = false;

    long long skip1 = 0;
    long long skip2 = 0;

    long long limit = LLONG_MAX;

    const char *file1 = NULL;
    const char *file2 = NULL;

    for (int i = 1; i < argc; i++) {

        if (strcmp(argv[i], "-b") == 0)
            opt_print_bytes = true;

        else if (strcmp(argv[i], "-l") == 0)
            opt_verbose = true;

        else if (strcmp(argv[i], "-s") == 0)
            opt_silent = true;

        else if (strcmp(argv[i], "-i") == 0) {
            if (++i >= argc)
                usage(argv[0]);

            skip1 = skip2 =
                parse_size(argv[i]);
        }

        else if (strcmp(argv[i], "-n") == 0) {
            if (++i >= argc)
                usage(argv[0]);

            limit = parse_size(argv[i]);
        }

        else if (strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
        }

        else if (strcmp(argv[i], "--version") == 0) {
            printf("cmp (portable) %s\n",
                   VERSION);
            return 0;
        }

        else if (!file1)
            file1 = argv[i];

        else if (!file2)
            file2 = argv[i];

        else
            usage(argv[0]);
    }

    if (!file1 || !file2)
        usage(argv[0]);

    FILE *f1 =
        strcmp(file1, "-") == 0
            ? stdin
            : fopen(file1, "rb");

    FILE *f2 =
        strcmp(file2, "-") == 0
            ? stdin
            : fopen(file2, "rb");

    if (!f1) {
        fprintf(stderr,
                "cmp: %s: %s\n",
                file1,
                strerror(errno));
        return 2;
    }

    if (!f2) {
        fprintf(stderr,
                "cmp: %s: %s\n",
                file2,
                strerror(errno));
        return 2;
    }

    skip_bytes(f1, skip1);
    skip_bytes(f2, skip2);

    unsigned char buf1[BUF_SIZE];
    unsigned char buf2[BUF_SIZE];

    long long pos = 1;
    long long line = 1;

    int status = 0;

    while (limit > 0) {

        size_t toread =
            limit > BUF_SIZE
                ? BUF_SIZE
                : (size_t)limit;

        size_t n1 =
            fread(buf1, 1, toread, f1);

        size_t n2 =
            fread(buf2, 1, toread, f2);

        size_t n =
            n1 < n2 ? n1 : n2;

        /* Fast memcmp path */

        if (n > 0 &&
            memcmp(buf1, buf2, n) == 0) {

            for (size_t j = 0; j < n; j++)
                if (buf1[j] == '\n')
                    line++;

            pos += n;

            limit -= n;

            if (n1 != n2)
                break;

            continue;
        }

        for (size_t j = 0; j < n;
             j++, pos++) {

            if (buf1[j] == '\n')
                line++;

            if (buf1[j] != buf2[j]) {

                status = 1;

                if (opt_silent)
                    goto done;

                if (opt_verbose) {

                    printf("%7lld %3o %3o\n",
                           pos,
                           buf1[j],
                           buf2[j]);

                } else {

                    printf(
                        "%s %s differ: byte %lld, line %lld\n",
                        file1,
                        file2,
                        pos,
                        line);

                    if (opt_print_bytes) {

                        char v1[8];
                        char v2[8];

                        visible_byte(
                            buf1[j], v1);
                        visible_byte(
                            buf2[j], v2);

                        printf(
                            " is %3o %s %3o %s\n",
                            buf1[j],
                            v1,
                            buf2[j],
                            v2);
                    }

                    goto done;
                }
            }
        }

        if (n1 != n2) {

            status = 1;

            if (!opt_silent) {

                fprintf(stderr,
                        "cmp: EOF on '%s' after byte %lld\n",
                        (n1 < n2
                             ? file1
                             : file2),
                        pos - 1);
            }

            break;
        }

        if (n1 == 0)
            break;

        limit -= n;
    }

done:

    fclose(f1);
    fclose(f2);

    return status;
}
