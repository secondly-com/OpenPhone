#import <Foundation/Foundation.h>

#import <errno.h>
#import <signal.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

static NSString *const OPDefaultStorePath = @"/var/mobile/Library/OpenPhone";

static NSString *OPSocketPath(void) {
    const char *override = getenv("OPENPHONE_AGENTD_STORE");
    NSString *storePath = (override && override[0] != '\0')
            ? [NSString stringWithUTF8String:override] : OPDefaultStorePath;
    return [[storePath stringByAppendingPathComponent:@"run"]
            stringByAppendingPathComponent:@"agentd.sock"];
}

static BOOL OPAgentCtlWriteAll(int fd, NSData *data) {
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written > 0) {
            bytes += written;
            remaining -= (NSUInteger)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        return NO;
    }
    return YES;
}

static NSString *OPRequestFromArguments(int argc, char **argv) {
    if (argc < 2 || argv[1] == NULL) {
        return @"{\"command\":\"health\"}";
    }
    NSString *first = [NSString stringWithUTF8String:argv[1]];
    if ([first hasPrefix:@"{"]) {
        return first;
    }
    NSArray<NSString *> *actionCommands = @[
        @"home",
        @"wake_and_home",
        @"show_passcode",
        @"unlock_with_passcode",
        @"wait",
        @"tap",
        @"tap_element",
        @"long_press",
        @"swipe",
        @"type_text",
        @"open_app",
        @"open_url"
    ];
    if ([actionCommands containsObject:first]) {
        NSMutableDictionary *action = [@{@"type": first} mutableCopy];
        if ([first isEqualToString:@"open_app"] && argc >= 3 && argv[2] != NULL) {
            action[@"target"] = @{@"package": [NSString stringWithUTF8String:argv[2]]};
        } else if ([first isEqualToString:@"open_url"] && argc >= 3 && argv[2] != NULL) {
            action[@"url"] = [NSString stringWithUTF8String:argv[2]];
        } else if ([first isEqualToString:@"unlock_with_passcode"] && argc >= 3 && argv[2] != NULL) {
            action[@"passcode"] = [NSString stringWithUTF8String:argv[2]];
        } else if ([first isEqualToString:@"wait"] && argc >= 3 && argv[2] != NULL) {
            action[@"duration_ms"] = @([[NSString stringWithUTF8String:argv[2]] integerValue]);
        } else if (([first isEqualToString:@"tap"] ||
                [first isEqualToString:@"long_press"]) && argc >= 4) {
            action[@"x"] = @([[NSString stringWithUTF8String:argv[2]] doubleValue]);
            action[@"y"] = @([[NSString stringWithUTF8String:argv[3]] doubleValue]);
            if ([first isEqualToString:@"long_press"] && argc >= 5 && argv[4] != NULL) {
                action[@"duration_ms"] = @([[NSString stringWithUTF8String:argv[4]] integerValue]);
            }
        } else if ([first isEqualToString:@"tap_element"] && argc >= 3 && argv[2] != NULL) {
            action[@"element_id"] = [NSString stringWithUTF8String:argv[2]];
            if (argc >= 5 && argv[3] != NULL && argv[4] != NULL) {
                action[@"x"] = @([[NSString stringWithUTF8String:argv[3]] doubleValue]);
                action[@"y"] = @([[NSString stringWithUTF8String:argv[4]] doubleValue]);
            }
        } else if ([first isEqualToString:@"swipe"] && argc >= 6) {
            action[@"start_x"] = @([[NSString stringWithUTF8String:argv[2]] doubleValue]);
            action[@"start_y"] = @([[NSString stringWithUTF8String:argv[3]] doubleValue]);
            action[@"end_x"] = @([[NSString stringWithUTF8String:argv[4]] doubleValue]);
            action[@"end_y"] = @([[NSString stringWithUTF8String:argv[5]] doubleValue]);
            if (argc >= 7 && argv[6] != NULL) {
                action[@"duration_ms"] = @([[NSString stringWithUTF8String:argv[6]] integerValue]);
            }
        } else if ([first isEqualToString:@"type_text"] && argc >= 3 && argv[2] != NULL) {
            NSMutableString *text = [NSMutableString string];
            for (int i = 2; i < argc; i++) {
                if (argv[i] == NULL) {
                    continue;
                }
                if (text.length > 0) {
                    [text appendString:@" "];
                }
                [text appendString:[NSString stringWithUTF8String:argv[i]] ?: @""];
            }
            action[@"text"] = text;
        }
        NSDictionary *request = @{@"command": @"execute_action", @"action": action};
        NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{\"command\":\"health\"}";
    }
    NSMutableDictionary *request = [@{@"command": first} mutableCopy];
    if (argc >= 3 && argv[2] != NULL) {
        NSString *second = [NSString stringWithUTF8String:argv[2]];
        if ([first isEqualToString:@"get_task"] ||
                [first isEqualToString:@"get_trajectory"] ||
                [first isEqualToString:@"stop_task"]) {
            request[@"task_id"] = second;
        } else if ([first isEqualToString:@"finish_task"]) {
            request[@"task_id"] = second;
            request[@"summary"] = @"agentctl finish_task";
        } else if ([first isEqualToString:@"fail_task"]) {
            request[@"task_id"] = second;
            request[@"reason"] = @"agentctl fail_task";
        } else if ([first isEqualToString:@"list_tasks"] ||
                [first isEqualToString:@"get_audit"]) {
            request[@"limit"] = @([second integerValue]);
        } else if ([first isEqualToString:@"model_configure"]) {
            request[@"mode"] = second;
        } else if ([first isEqualToString:@"agent_control"]) {
            request[@"action"] = second;
            request[@"source"] = @"openphone-agentctl";
            if ([second isEqualToString:@"pause"]) {
                request[@"reason"] = @"agentctl pause";
            }
        } else if ([first isEqualToString:@"list_apps"]) {
            NSInteger limit = [second integerValue];
            if (limit > 0 || [second isEqualToString:@"0"]) {
                request[@"limit"] = @(limit);
            } else {
                request[@"query"] = second;
            }
        } else if ([first isEqualToString:@"get_screen"]) {
            NSString *lower = second.lowercaseString;
            if ([lower isEqualToString:@"screenshot"] || [lower isEqualToString:@"capture"]
                    || [lower isEqualToString:@"true"] || [lower isEqualToString:@"1"]) {
                request[@"include_screenshot"] = @YES;
            }
        } else if ([first isEqualToString:@"memory_save"]) {
            request[@"text"] = second;
            request[@"reason"] = @"agentctl memory_save";
        } else if ([first isEqualToString:@"memory_update"]) {
            request[@"memory_id"] = second;
            request[@"reason"] = @"agentctl memory_update";
        } else if ([first isEqualToString:@"memory_delete"]) {
            request[@"memory_id"] = second;
            request[@"reason"] = @"agentctl memory_delete";
        } else if ([first isEqualToString:@"memory_merge"]) {
            request[@"target_memory_id"] = second;
            request[@"reason"] = @"agentctl memory_merge";
        } else if ([first isEqualToString:@"memory_search"] ||
                [first isEqualToString:@"context_search"]) {
            request[@"query"] = second;
            request[@"reason"] = @"agentctl search";
        } else if ([first isEqualToString:@"commitment_create"]) {
            request[@"title"] = second;
            request[@"reason"] = @"agentctl commitment_create";
        } else if ([first isEqualToString:@"commitment_search"]) {
            request[@"query"] = second;
            request[@"reason"] = @"agentctl commitment_search";
        } else if ([first isEqualToString:@"commitment_update_status"]) {
            request[@"commitment_id"] = second;
            request[@"reason"] = @"agentctl commitment_update_status";
        } else if ([first isEqualToString:@"commitment_run_due"]) {
            request[@"limit"] = @([second integerValue]);
            request[@"reason"] = @"agentctl commitment_run_due";
        } else if ([first isEqualToString:@"watcher_create"]) {
            request[@"title"] = second;
            request[@"reason"] = @"agentctl watcher_create";
        } else if ([first isEqualToString:@"watcher_list"]) {
            request[@"query"] = second;
            request[@"reason"] = @"agentctl watcher_list";
        } else if ([first isEqualToString:@"watcher_stop"]) {
            if ([second isEqualToString:@"all"]) {
                request[@"all"] = @YES;
            } else {
                request[@"watcher_id"] = second;
            }
            request[@"reason"] = @"agentctl watcher_stop";
        } else if ([first isEqualToString:@"background_job_create"]) {
            request[@"title"] = second;
            NSMutableString *prompt = [NSMutableString string];
            for (int i = 3; i < argc; i++) {
                if (argv[i] == NULL) {
                    continue;
                }
                if (prompt.length > 0) {
                    [prompt appendString:@" "];
                }
                [prompt appendString:[NSString stringWithUTF8String:argv[i]] ?: @""];
            }
            if (prompt.length > 0) {
                request[@"prompt"] = prompt;
            }
            request[@"reason"] = @"agentctl background_job_create";
        } else if ([first isEqualToString:@"background_job_list"]) {
            request[@"query"] = second;
            request[@"reason"] = @"agentctl background_job_list";
        } else if ([first isEqualToString:@"background_job_stop"]) {
            request[@"job_id"] = second;
            request[@"reason"] = @"agentctl background_job_stop";
        } else if ([first isEqualToString:@"background_job_run_due"]) {
            request[@"limit"] = @([second integerValue]);
            request[@"reason"] = @"agentctl background_job_run_due";
        } else if ([first isEqualToString:@"hardware_trigger"]) {
            request[@"trigger"] = second;
            request[@"source"] = @"agentctl";
            request[@"reason"] = @"agentctl hardware_trigger";
        } else {
            request[@"goal"] = second;
        }
    }
    if (argc >= 4 && argv[3] != NULL) {
        NSString *third = [NSString stringWithUTF8String:argv[3]];
        if ([first isEqualToString:@"stop_task"]) {
            request[@"reason"] = third;
        } else if ([first isEqualToString:@"finish_task"]) {
            request[@"summary"] = third;
        } else if ([first isEqualToString:@"fail_task"]) {
            request[@"reason"] = third;
        } else if ([first isEqualToString:@"model_configure"]) {
            request[@"endpoint_url"] = third;
        } else if ([first isEqualToString:@"agent_control"]) {
            request[@"reason"] = third;
        } else if ([first isEqualToString:@"run_task"]) {
            NSString *lower = third.lowercaseString;
            if ([lower isEqualToString:@"model"] || [lower isEqualToString:@"auto"] ||
                    [lower isEqualToString:@"deterministic"]) {
                request[@"mode"] = lower;
            } else {
                request[@"max_steps"] = @([third integerValue]);
            }
        } else if ([first isEqualToString:@"memory_save"]) {
            request[@"type"] = third;
        } else if ([first isEqualToString:@"memory_update"]) {
            request[@"text"] = third;
        } else if ([first isEqualToString:@"memory_delete"]) {
            request[@"reason"] = third;
        } else if ([first isEqualToString:@"memory_merge"]) {
            request[@"source_memory_id"] = third;
        } else if ([first isEqualToString:@"memory_search"] ||
                [first isEqualToString:@"context_search"]) {
            request[@"limit"] = @([third integerValue]);
        } else if ([first isEqualToString:@"commitment_create"]) {
            if ([third longLongValue] > 0) {
                request[@"due_at"] = @([third longLongValue]);
            } else {
                request[@"description"] = third;
            }
        } else if ([first isEqualToString:@"commitment_search"]) {
            request[@"limit"] = @([third integerValue]);
        } else if ([first isEqualToString:@"commitment_update_status"]) {
            request[@"status"] = third;
        } else if ([first isEqualToString:@"commitment_run_due"]) {
            request[@"source"] = third;
        } else if ([first isEqualToString:@"watcher_create"]) {
            request[@"source"] = third;
        } else if ([first isEqualToString:@"watcher_list"]) {
            request[@"limit"] = @([third integerValue]);
        } else if ([first isEqualToString:@"watcher_stop"]) {
            request[@"reason"] = third;
        } else if ([first isEqualToString:@"background_job_list"]) {
            request[@"limit"] = @([third integerValue]);
        } else if ([first isEqualToString:@"background_job_stop"]) {
            request[@"reason"] = third;
        } else if ([first isEqualToString:@"background_job_run_due"]) {
            request[@"max_steps"] = @([third integerValue]);
        } else if ([first isEqualToString:@"hardware_trigger"]) {
            request[@"goal"] = third;
        } else {
            request[@"limit"] = @([third integerValue]);
        }
    }
    if (argc >= 5 && argv[4] != NULL && [first isEqualToString:@"run_task"]) {
        NSString *fourth = [NSString stringWithUTF8String:argv[4]];
        if (request[@"mode"]) {
            request[@"max_steps"] = @([fourth integerValue]);
        } else {
            request[@"max_duration_ms"] = @([fourth integerValue]);
        }
    } else if (argc >= 5 && argv[4] != NULL && [first isEqualToString:@"model_configure"]) {
        NSString *fourth = [NSString stringWithUTF8String:argv[4]];
        request[@"model"] = fourth;
    } else if (argc >= 5 && argv[4] != NULL && [first isEqualToString:@"background_job_run_due"]) {
        NSString *fourth = [NSString stringWithUTF8String:argv[4]];
        request[@"max_duration_ms"] = @([fourth integerValue]);
    } else if (argc >= 5 && argv[4] != NULL && [first isEqualToString:@"memory_save"]) {
        NSString *fourth = [NSString stringWithUTF8String:argv[4]];
        request[@"subject"] = fourth;
    } else if (argc >= 5 && argv[4] != NULL && [first isEqualToString:@"memory_update"]) {
        NSString *fourth = [NSString stringWithUTF8String:argv[4]];
        request[@"type"] = fourth;
    } else if (argc >= 5 && argv[4] != NULL && [first isEqualToString:@"memory_merge"]) {
        NSString *fourth = [NSString stringWithUTF8String:argv[4]];
        request[@"text"] = fourth;
    }
    if (argc >= 6 && argv[5] != NULL && [first isEqualToString:@"memory_update"]) {
        NSString *fifth = [NSString stringWithUTF8String:argv[5]];
        request[@"subject"] = fifth;
    } else if (argc >= 6 && argv[5] != NULL && [first isEqualToString:@"run_task"] && request[@"mode"]) {
        NSString *fifth = [NSString stringWithUTF8String:argv[5]];
        request[@"max_duration_ms"] = @([fifth integerValue]);
    } else if (argc >= 6 && argv[5] != NULL && [first isEqualToString:@"model_configure"]) {
        NSString *fifth = [NSString stringWithUTF8String:argv[5]];
        request[@"enabled"] = @([fifth boolValue]);
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{\"command\":\"health\"}";
}

int main(int argc, char **argv) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        NSString *request = OPRequestFromArguments(argc, argv);
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) {
            fprintf(stderr, "socket failed: %s\n", strerror(errno));
            return 1;
        }

        struct sockaddr_un address;
        memset(&address, 0, sizeof(address));
        address.sun_family = AF_UNIX;
        NSString *socketPath = OPSocketPath();
        strlcpy(address.sun_path, socketPath.UTF8String, sizeof(address.sun_path));

        if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
            fprintf(stderr, "connect %s failed: %s\n", socketPath.UTF8String, strerror(errno));
            close(fd);
            return 1;
        }

        NSData *requestData = [[request stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        if (!OPAgentCtlWriteAll(fd, requestData)) {
            fprintf(stderr, "write failed: %s\n", strerror(errno));
            close(fd);
            return 1;
        }
        shutdown(fd, SHUT_WR);

        char buffer[4096];
        while (true) {
            ssize_t count = read(fd, buffer, sizeof(buffer));
            if (count > 0) {
                fwrite(buffer, 1, (size_t)count, stdout);
                continue;
            }
            break;
        }
        close(fd);
    }
    return 0;
}
