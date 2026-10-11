#import <Carbon/Carbon.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>

// 独立进程只向指定私有命名板连续写入带序号文本，by AI.Coding。
int main(int argc, const char *argv[]) {
    if (argc != 3) return 2;
    CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault, argv[1], kCFStringEncodingUTF8);
    PasteboardRef board = NULL;
    OSStatus status = PasteboardCreate(name, &board);
    CFRelease(name);
    if (status != noErr || board == NULL) return 3;
    const int count = atoi(argv[2]);
    for (int index = 0; index < count; index++) {
        CFStringRef text = CFStringCreateWithFormat(kCFAllocatorDefault, NULL, CFSTR("LOCALCLIP-SOAK-%05d"), index);
        CFDataRef data = CFStringCreateExternalRepresentation(kCFAllocatorDefault, text, kCFStringEncodingUTF8, 0);
        CFRelease(text);
        status = PasteboardClear(board);
        if (status == noErr) status = PasteboardPutItemFlavor(board, (PasteboardItemID)1, CFSTR("public.utf8-plain-text"), data, 0);
        CFRelease(data);
        if (status == noErr) status = PasteboardSynchronize(board);
        if (status != noErr) {
            fprintf(stderr, "private named pasteboard write failed at input %d: %d\n", index, (int)status);
            CFRelease(board);
            return 4;
        }
        if ((index + 1) % 100 == 0) usleep(1000);
    }
    printf("%d\n", count);
    CFRelease(board);
    return 0;
}
