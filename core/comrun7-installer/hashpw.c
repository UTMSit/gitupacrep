#define _XOPEN_SOURCE 700
#include <crypt.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Tiny helper used by the installer and comrun7-adduser.  It reads a password
   from stdin (or argv[1] for non-interactive tests) and prints a SHA-512
   crypt hash.  No password is written to the command line by the installer. */
static unsigned char random_byte(void) {
    static int fd = -1;
    unsigned char b;
    if (fd < 0) fd = open("/dev/urandom", O_RDONLY);
    if (fd >= 0 && read(fd, &b, 1) == 1) return b;
    return (unsigned char)(clock() ^ (unsigned)getpid() ^ (unsigned)time(NULL));
}

int main(int argc, char **argv) {
    char pw[512];
    const char *password;

    if (argc > 2) {
        fprintf(stderr, "usage: comrun7-hashpw [PASSWORD]\n");
        return 2;
    }
    if (argc == 2) {
        password = argv[1];
    } else {
        if (!fgets(pw, sizeof(pw), stdin)) {
            fprintf(stderr, "comrun7-hashpw: cannot read password\n");
            return 1;
        }
        size_t n = strlen(pw);
        while (n && (pw[n - 1] == '\n' || pw[n - 1] == '\r')) pw[--n] = 0;
        password = pw;
    }

    static const char alphabet[] =
        "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    char salt[40];
    memcpy(salt, "$6$", 3);
    for (int i = 0; i < 16; i++)
        salt[3 + i] = alphabet[random_byte() % (sizeof(alphabet) - 1)];
    salt[19] = 0;

    char *hash = crypt(password, salt);
    if (!hash) {
        fprintf(stderr, "comrun7-hashpw: crypt failed: %s\n", strerror(errno));
        return 1;
    }
    puts(hash);
    return 0;
}
