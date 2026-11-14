// Updates from inside the app (runtime/update.c): the latest GitHub release offered on the start screen.
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { UPDATE_NONE, UPDATE_CHECKING, UPDATE_AVAILABLE, UPDATE_DOWNLOADING, UPDATE_READY, UPDATE_FAILED };

void update_check_start(void);      // once, from the launcher (a thread of its own)
int update_state(void);             // UPDATE_*
const char *update_latest(void);    // the latest release's tag
const char *update_error(void);     // UPDATE_FAILED: why, in a few words
float update_progress(void);        // UPDATE_DOWNLOADING: 0..1
int update_downloaded_mb(void);     // UPDATE_DOWNLOADING: MB of the zip downloaded so far
void update_install_start(void);    // download and unpack it (a thread of its own)
void update_apply_and_exit(void);   // UPDATE_READY: hand over to the installer script and end this program

#ifdef __cplusplus
}
#endif
