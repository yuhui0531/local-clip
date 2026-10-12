#import <AppKit/AppKit.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>

// 独立进程只向指定私有命名板连续写入带序号文本并记录世代，by AI.Coding。
int main(int argc, const char *argv[]) {
    if (argc != 4) return 2;
    @autoreleasepool {
        NSApplicationLoad();
        FILE *receipts = fopen(argv[3], "w");
        if (receipts == NULL) return 2;
        NSPasteboard *board = [NSPasteboard pasteboardWithName:[NSString stringWithUTF8String:argv[1]]];
        const int count = atoi(argv[2]);
        for (int index = 0; index < count; index++) {
            @autoreleasepool {
                NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
                [item setString:[NSString stringWithFormat:@"LOCALCLIP-SOAK-%05d", index] forType:NSPasteboardTypeString];
                [board clearContents];
                if (![board writeObjects:@[item]]) {
                    fprintf(stderr, "private named pasteboard write failed at input %d\n", index);
                    fclose(receipts);
                    return 4;
                }
                // 仅记录私有板写入世代，跳过事件无需读取正文即可对应输入，by AI.Coding。
                fprintf(receipts, "%d %ld\n", index, (long)board.changeCount);
            }
            if ((index + 1) % 100 == 0) usleep(1000);
        }
        fclose(receipts);
        printf("%d\n", count);
        return 0;
    }
}
