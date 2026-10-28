// Pure command/ring tests: Foundation JSON objects only; never run the native
// entrypoint, AppKit, socket connect, TCC or any CoreAudio function.
#define main unused_native_main
#include "phonebridge-pcm.mm"
#undef main
static void check(bool value, const char *label) { if (!value) { fprintf(stderr, "FAIL: %s\n", label); exit(1); } }
int main() { @autoreleasepool {
    auto shared = std::make_unique<SharedAudio>(); PrivateIPC ipc; OutputCommands commands(*shared, ipc);
    uint8_t pcm[] = {0, 64, 0, 64, 0, 64, 0, 64, 0, 64, 0, 64};
    NSString *audio = [[NSData dataWithBytes:pcm length:sizeof(pcm)] base64EncodedStringWithOptions:0];
    NSMutableDictionary *chunk = [@{@"op": @"output_audio", @"generation": @0, @"response_id": @"resp-1", @"item_id": @"item-1", @"content_index": @0, @"audio": audio} mutableCopy];
    check(commands.command(chunk) && shared->output.available() == 2, "first output chunk");
    check(commands.command(@{@"op": @"clear_output", @"generation": @1}) && commands.waitingClear, "clear increments generation");
    size_t oldCount = shared->output.available(); chunk[@"generation"] = @1;
    check(commands.command(chunk) && shared->output.available() == oldCount && commands.items.size() == 1, "new generation cannot enqueue before acknowledgment");
    float buffer[4]; shared->render(buffer, 4); check(commands.progress() && !commands.waitingClear && shared->output.available() == 0, "callback observed clear before ack");
    check(commands.command(chunk) && commands.items.size() == 2 && shared->output.available() == 2, "new generation accepted after ack");
    chunk[@"generation"] = @0; oldCount = shared->output.available();
    check(commands.command(chunk) && shared->output.available() == oldCount && commands.items.size() == 2, "late old generation rejected without enqueue");
    check(commands.command(@{@"op": @"output_end", @"generation": @1, @"response_id": @"resp-1", @"item_id": @"item-1", @"content_index": @0}) && commands.current == -1, "item end flushes finite FIR tail");
    shared->render(buffer, 4); check(shared->counters[1].position8.load() == 0, "FIR startup delay does not advance source position");
    while (shared->output.available()) shared->render(buffer, 4);
    check(shared->counters[1].position8.load() == 2, "FIR tail cannot advance truncation beyond source duration");
    chunk[@"generation"] = @1; check(!commands.command(chunk), "finished identity cannot reopen");
    auto shared2 = std::make_unique<SharedAudio>(); PrivateIPC ipc2; OutputCommands commands2(*shared2, ipc2);
    chunk[@"generation"] = @YES; check(!commands2.command(chunk), "boolean is not generation");
    chunk[@"generation"] = @0; [chunk removeObjectForKey:@"generation"]; check(!commands2.command(chunk), "generation is required");
    puts("{\"passed\":true,\"checks\":12,\"deviceIO\":false,\"socketConnected\":false,\"appKitInitialized\":false}"); return 0;
} }
