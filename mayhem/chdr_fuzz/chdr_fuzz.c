/* libFuzzer harness for libchdr (86Box's CHD reader): open a CHD from memory, decode every hunk and
 * walk the metadata. Ported from src/cdrom/libchdr/tests/fuzz.c, extended with the metadata walk. */
#include <libchdr/chd.h>
#include <libchdr/coretypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  const uint8_t *buffer;
  size_t buffer_size;
  size_t buffer_pos;
} membuf;

static uint64_t membuf_fsize(struct chd_core_file *cf) {
  return ((membuf *)cf->argp)->buffer_size;
}

static size_t membuf_fread(void *buf, size_t size, size_t count,
                           struct chd_core_file *cf) {
  membuf *mb = (membuf *)cf->argp;
  if (size == 0 || (UINT32_MAX / size) < count)
    return 0;
  size_t copy = size * count;
  size_t remain = mb->buffer_size - mb->buffer_pos;
  if (remain < copy)
    copy = remain;
  memcpy(buf, &mb->buffer[mb->buffer_pos], copy);
  mb->buffer_pos += copy;
  return copy;
}

static int membuf_fclose(struct chd_core_file *cf) { return 0; }

static int membuf_fseek(struct chd_core_file *cf, int64_t pos, int origin) {
  membuf *mb = (membuf *)cf->argp;
  if (origin == SEEK_SET) {
    if (pos < 0 || (size_t)pos > mb->buffer_size)
      return -1;
    mb->buffer_pos = (size_t)pos;
    return 0;
  } else if (origin == SEEK_CUR) {
    if (pos < 0 && (size_t)-pos > mb->buffer_pos)
      return -1;
    else if ((mb->buffer_pos + (size_t)pos) > mb->buffer_size)
      return -1;
    mb->buffer_pos =
        (pos < 0) ? (mb->buffer_pos - (size_t)-pos) : (mb->buffer_pos + pos);
    return 0;
  } else if (origin == SEEK_END) {
    mb->buffer_pos = mb->buffer_size;
    return 0;
  } else {
    return -1;
  }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  unsigned int i;
  void *buffer;
  char meta[512];
  membuf mb = {data, size, 0u};
  struct chd_core_file cf = {&mb, membuf_fsize, membuf_fread, membuf_fclose,
                             membuf_fseek};
  chd_file *file;
  const chd_header *header;
  chd_error err = chd_open_core_file(&cf, CHD_OPEN_READ, NULL, &file);
  if (err != CHDERR_NONE)
    return -1;

  header = chd_get_header(file);
  buffer = malloc(header->hunkbytes);
  if (buffer != NULL) {
    for (i = 0; i < header->totalhunks; i++)
      (void)chd_read(file, i, buffer);
    free(buffer);
  }
  for (i = 0; i < 8; i++) {
    uint32_t len, tag;
    uint8_t flags;
    if (chd_get_metadata(file, CHDMETATAG_WILDCARD, i, meta, sizeof(meta), &len,
                         &tag, &flags) != CHDERR_NONE)
      break;
  }
  chd_close(file);
  return 0;
}
