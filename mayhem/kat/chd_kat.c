/* Known-answer probe for libchdr: open each CHD given on argv, print header fields, a hash of every
 * decoded hunk and the first metadata entries. mayhem/test.sh diffs the output against expected.txt. */
#include <libchdr/chd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t fnv1a(const uint8_t *p, size_t n) {
  uint32_t h = 2166136261u;
  while (n--) {
    h ^= *p++;
    h *= 16777619u;
  }
  return h;
}

static const char *base(const char *p) {
  const char *s = strrchr(p, '/');
  return s ? s + 1 : p;
}

int main(int argc, char **argv) {
  int i;
  for (i = 1; i < argc; i++) {
    chd_file *f = NULL;
    const chd_header *h;
    uint32_t n;
    uint8_t *buf;
    chd_error err = chd_open(argv[i], CHD_OPEN_READ, NULL, &f);
    if (err != CHDERR_NONE) {
      printf("FILE %s: open error %d (%s)\n", base(argv[i]), (int)err, chd_error_string(err));
      continue;
    }
    h = chd_get_header(f);
    printf("FILE %s: version=%u hunkbytes=%u hunks=%u unitbytes=%u logical=%llu codec0=%.4s\n",
           base(argv[i]), h->version, h->hunkbytes, h->totalhunks, h->unitbytes,
           (unsigned long long)h->logicalbytes,
           h->compression[0] ? (const char *)(char[5]){(char)(h->compression[0] >> 24), (char)(h->compression[0] >> 16),
                                                        (char)(h->compression[0] >> 8), (char)h->compression[0], 0}
                             : "none");
    buf = malloc(h->hunkbytes);
    for (n = 0; n < h->totalhunks; n++) {
      err = chd_read(f, n, buf);
      if (err != CHDERR_NONE)
        printf("hunk %u: read error %d\n", n, (int)err);
      else
        printf("hunk %u: fnv=%08x\n", n, fnv1a(buf, h->hunkbytes));
    }
    free(buf);
    {
      char meta[256];
      uint32_t len, tag;
      uint8_t flags;
      uint32_t idx;
      for (idx = 0; idx < 4; idx++) {
        err = chd_get_metadata(f, CHDMETATAG_WILDCARD, idx, meta, sizeof(meta) - 1, &len, &tag, &flags);
        if (err != CHDERR_NONE)
          break;
        meta[len < sizeof(meta) - 1 ? len : sizeof(meta) - 1] = 0;
        printf("meta %u: tag=%c%c%c%c data=%s\n", idx, (char)(tag >> 24), (char)(tag >> 16), (char)(tag >> 8),
               (char)tag, meta);
      }
    }
    chd_close(f);
  }
  return 0;
}
