// idslog - SSH-friendly log stream (logcat-style) for iMessage/IDS debugging.
// Based on limneos/oslog; avoids the broken Procursus oslog predicate path.

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <Foundation/Foundation.h>
#include "ActivityStreamAPI.h"

static BOOL g_canPrint = NO;
static int g_filterPid = -1;
static BOOL g_matchAll = NO;
static NSMutableArray<NSString *> *g_nameFilters = nil;

static int (*g_proc_name)(int pid, char *buffer, unsigned int size);
static int (*g_proc_listpids)(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
static uint8_t (*g_os_log_get_type)(void *log);

static os_activity_stream_for_pid_t s_stream_for_pid;
static os_activity_stream_resume_t s_stream_resume;
static os_activity_stream_cancel_t s_stream_cancel;
static os_activity_stream_set_event_handler_t s_stream_set_event;
static os_log_copy_formatted_message_t s_copy_message;

static void usage(void) {
    fprintf(stderr,
        "usage: idslog [--info] [--debug] [-p pid|name] [process ...]\n\n"
        "examples:\n"
        "  idslog identityservicesd imagent apsd akd\n"
        "  idslog --debug --info identityservicesd\n"
        "  idslog -p identityservicesd\n"
        "  idslog | tee /tmp/ids.log\n");
}

static BOOL lookupSPI(void) {
    dlopen("/System/Library/PrivateFrameworks/LoggingSupport.framework/LoggingSupport", RTLD_NOW);
    s_stream_for_pid = (os_activity_stream_for_pid_t)dlsym(RTLD_DEFAULT, "os_activity_stream_for_pid");
    s_stream_resume = (os_activity_stream_resume_t)dlsym(RTLD_DEFAULT, "os_activity_stream_resume");
    s_stream_cancel = (os_activity_stream_cancel_t)dlsym(RTLD_DEFAULT, "os_activity_stream_cancel");
    s_stream_set_event = (os_activity_stream_set_event_handler_t)dlsym(RTLD_DEFAULT, "os_activity_stream_set_event_handler");
    s_copy_message = (os_log_copy_formatted_message_t)dlsym(RTLD_DEFAULT, "os_log_copy_formatted_message");
    g_proc_name = (int (*)(int, char *, unsigned int))dlsym(RTLD_DEFAULT, "proc_name");
    g_proc_listpids = (int (*)(uint32_t, uint32_t, void *, int))dlsym(RTLD_DEFAULT, "proc_listpids");
    g_os_log_get_type = (uint8_t (*)(void *))dlsym(RTLD_DEFAULT, "os_log_get_type");

    return s_stream_for_pid && s_stream_resume && s_stream_cancel && s_stream_set_event
        && s_copy_message && g_proc_name && g_proc_listpids && g_os_log_get_type;
}

static BOOL procMatchesFilters(const char *procname) {
    if (g_matchAll || g_nameFilters.count == 0) return YES;
    if (!procname) return NO;
    for (NSString *f in g_nameFilters) {
        if (strstr(procname, f.UTF8String)) return YES;
    }
    return NO;
}

static BOOL handleEntry(os_activity_stream_entry_t entry, int error) {
    if (!g_canPrint || error || !entry) return YES;
    if (g_filterPid != -1 && entry->pid != g_filterPid) return YES;

    char procname[64] = {0};
    g_proc_name(entry->pid, procname, sizeof(procname));
    if (!procMatchesFilters(procname)) return YES;

    if (entry->type != OS_ACTIVITY_STREAM_TYPE_LOG_MESSAGE
        && entry->type != OS_ACTIVITY_STREAM_TYPE_LEGACY_LOG_MESSAGE) {
        return YES;
    }

    os_log_message_t log_message = &entry->log_message;
    char *messageText = s_copy_message(log_message);
    if (!messageText && log_message->format) {
        messageText = (char *)log_message->format;
    }
    if (!messageText) return YES;

    char timebuffer[32];
    struct timeval tv;
    gettimeofday(&tv, NULL);
    strftime(timebuffer, sizeof(timebuffer), "%H:%M:%S", localtime(&tv.tv_sec));

    const char *sub = (log_message->subsystem && log_message->subsystem[0]) ? log_message->subsystem : "";
    const char *cat = (log_message->category && log_message->category[0]) ? log_message->category : "";

    printf("%s %s[%d] %s/%s: %s\n", timebuffer, procname, entry->pid, sub, cat, messageText);
    fflush(stdout);
    return YES;
}

static int resolvePid(NSString *nameOrPid) {
    int pid = nameOrPid.intValue;
    if (pid > 0 && [nameOrPid isEqualToString:[NSString stringWithFormat:@"%d", pid]]) {
        return pid;
    }

    int bufsize = g_proc_listpids(1, 0, NULL, 0);
    if (bufsize <= 0) return -1;
    pid_t *pids = (pid_t *)calloc(1, bufsize);
    g_proc_listpids(1, 0, pids, bufsize);
    size_t num = bufsize / sizeof(pid_t);
    for (size_t i = 0; i < num; i++) {
        char procname[64] = {0};
        g_proc_name(pids[i], procname, sizeof(procname));
        if (strstr(procname, nameOrPid.UTF8String)) {
            int found = pids[i];
            free(pids);
            return found;
        }
    }
    free(pids);
    return -1;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (!lookupSPI()) {
            fprintf(stderr, "idslog: LoggingSupport SPI unavailable\n");
            return 1;
        }

        g_nameFilters = [NSMutableArray array];
        uint32_t flags = OS_ACTIVITY_STREAM_INFO | OS_ACTIVITY_STREAM_DEBUG;

        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"--help"] || [arg isEqualToString:@"-h"]) {
                usage();
                return 0;
            }
            if ([arg isEqualToString:@"--info"]) continue;
            if ([arg isEqualToString:@"--debug"]) continue;
            if ([arg isEqualToString:@"--all"]) {
                g_matchAll = YES;
                continue;
            }
            if ([arg isEqualToString:@"-p"]) {
                if (i + 1 >= argc) { usage(); return 1; }
                g_filterPid = resolvePid([NSString stringWithUTF8String:argv[++i]]);
                if (g_filterPid < 0) {
                    fprintf(stderr, "idslog: process not found: %s\n", argv[i]);
                    return 1;
                }
                flags |= OS_ACTIVITY_STREAM_PROCESS_ONLY;
                continue;
            }
            [g_nameFilters addObject:arg];
        }

        if (g_nameFilters.count == 0 && g_filterPid == -1) {
            [g_nameFilters addObjectsFromArray:@[@"identityservicesd", @"imagent", @"apsd", @"akd"]];
        }

        os_activity_stream_block_t block = ^bool(os_activity_stream_entry_t entry, int error) {
            return handleEntry(entry, error);
        };

        os_activity_stream_event_block_t eventBlock = ^(os_activity_stream_t stream, os_activity_stream_event_t event) {
            (void)stream;
            switch (event) {
                case OS_ACTIVITY_STREAM_EVENT_STARTED:
                    g_canPrint = YES;
                    fprintf(stderr, "[idslog] streaming (Ctrl+C to stop). filters:");
                    if (g_filterPid != -1) fprintf(stderr, " pid=%d", g_filterPid);
                    for (NSString *f in g_nameFilters) fprintf(stderr, " %s", f.UTF8String);
                    fprintf(stderr, "\n");
                    break;
                case OS_ACTIVITY_STREAM_EVENT_FAILED:
                    fprintf(stderr, "[idslog] stream failed\n");
                    break;
                case OS_ACTIVITY_STREAM_EVENT_STOPPED:
                    fprintf(stderr, "[idslog] stream stopped\n");
                    break;
                default:
                    break;
            }
        };

        os_activity_stream_t stream = s_stream_for_pid(g_filterPid, flags, block);
        s_stream_set_event(stream, eventBlock);
        s_stream_resume(stream);

        [[NSRunLoop currentRunLoop] run];
        s_stream_cancel(stream);
        return 0;
    }
}
