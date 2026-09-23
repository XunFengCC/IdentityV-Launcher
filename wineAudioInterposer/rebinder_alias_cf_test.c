#include <CoreFoundation/CoreFoundation.h>
#include <assert.h>
static CFStringRef copy_name(void) { return CFStringCreateCopy(NULL, CFSTR("System Default Microphone")); }
static CFStringRef copy_uid(void) { return CFStringCreateCopy(NULL, CFSTR("com.xunfeng.identityv.system-default-input.v1")); }
int main(void) { CFStringRef name=copy_name(), uid=copy_uid(); assert(name&&uid); assert(CFEqual(name,CFSTR("System Default Microphone"))); assert(CFEqual(uid,CFSTR("com.xunfeng.identityv.system-default-input.v1"))); CFRelease(name); CFRelease(uid); return 0; }
