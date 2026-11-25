// Run via native_smoke.py; all data belongs to a temporary directory.
#include "../macos/Bridge.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
int main(int argc, char **argv) {
    assert(argc == 4);
    int result = bt_open(argv[1], argv[2]);
    if (!strcmp(argv[3], "locked")) {
        assert(result == -1);
        assert(!strcmp(bt_error(), "HistoryLocked"));
        return 0;
    }
    if (!strcmp(argv[3], "unfinished")) {
        assert(result == -1);
        assert(!strcmp(bt_error(), "UnfinishedSessionUseTUIRecovery"));
        return 0;
    }
    assert(result == 0);
    if (!strcmp(argv[3], "totals")) {
        const char *json = bt_totals();
        assert(json);
        puts(json);
        assert(bt_totals() == json); // Idle reads reuse the snapshot.
        assert(bt_close() == 0);
        return 0;
    }
    assert(bt_count() == 2);
    unsigned char name[64];
    assert(bt_name(0, name, sizeof name) == 5);
    assert(!strcmp((char *)name, "Work"));
    assert(bt_select(20) == -1);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) { execl(argv[0], argv[0], argv[1], argv[2], "locked", NULL); _exit(99); }
    int status;
    assert(waitpid(child, &status, 0) == child && status == 0);
    assert(bt_select(0) == 0 && bt_running() == 0);
    assert(bt_close() == -1); // Never abandon a live session implicitly.
    assert(bt_totals());
    sleep(1);
    assert(bt_totals()); // Live refresh is exercised; exact attribution is unit-tested.
    uint64_t live_seconds;
    assert(bt_elapsed(&live_seconds) == 0 && live_seconds >= 1);
    uint64_t seconds;
    assert(bt_elapsed(&seconds) == 0);
    assert(bt_select(1) == 0 && bt_running() == 1);
    assert(bt_select(1) == 0 && bt_running() == -1);
    assert(bt_select(0) == 0);
    assert(bt_select(-1) == 0);
    assert(bt_close() == 0);
    assert(bt_open(argv[1], argv[2]) == 0 && bt_running() == -1);
    assert(bt_select(0) == 0); // Deliberately simulate a crash for recovery refusal.
    return 0;
}
