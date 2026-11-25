#include <stddef.h>
#include <stdint.h>
// Main-thread only. -1 indicates failure; bt_error is a borrowed error name.
const char *bt_error(void);
int bt_open(const char *config, const char *history);
size_t bt_count(void);
size_t bt_name(size_t index, unsigned char *buffer, size_t capacity);
intptr_t bt_running(void);
int bt_elapsed(uint64_t *seconds);
int bt_select(intptr_t index); // -1 stops; selecting the running activity stops it.
int bt_close(void);
// Read-only JSON snapshot. NULL on failure; borrowed until next refresh/close.
const char *bt_totals(void);
