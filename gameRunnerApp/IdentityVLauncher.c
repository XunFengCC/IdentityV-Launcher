#import <AppKit/AppKit.h>

#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

static void show_error(const char *message) {
  fprintf(stderr, "IdentityV launcher: %s\n", message);

  @autoreleasepool {
    [NSApplication sharedApplication];
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"第五人格 Mac 无法启动"];
    [alert setInformativeText:[NSString stringWithUTF8String:message]];
    [alert addButtonWithTitle:@"好"];
    [alert runModal];
  }
}

static int executable_path(char *out, size_t out_size) {
  uint32_t size = (uint32_t)out_size;
  if (_NSGetExecutablePath(out, &size) != 0) {
    return -1;
  }

  char resolved[PATH_MAX];
  if (realpath(out, resolved) == NULL ||
      strlcpy(out, resolved, out_size) >= out_size) {
    return -1;
  }
  return 0;
}

static int join_path(char *out, size_t out_size, const char *directory,
                     const char *name) {
  return snprintf(out, out_size, "%s/%s", directory, name) >=
         (int)out_size
             ? -1
             : 0;
}

static void set_default_environment(void) {
  if (getenv("PATH") == NULL || getenv("PATH")[0] == '\0') {
    setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1);
  }
  if (getenv("LANG") == NULL || getenv("LANG")[0] == '\0') {
    setenv("LANG", "C.UTF-8", 1);
  }
  if (getenv("LC_ALL") == NULL || getenv("LC_ALL")[0] == '\0') {
    setenv("LC_ALL", "C.UTF-8", 1);
  }
  if (getenv("LC_CTYPE") == NULL || getenv("LC_CTYPE")[0] == '\0') {
    setenv("LC_CTYPE", "C.UTF-8", 1);
  }
  if (getenv("TERM") == NULL || getenv("TERM")[0] == '\0') {
    setenv("TERM", "dumb", 1);
  }
  setenv("COMMAND_MODE", "unix2003", 0);
  setenv("MallocNanoZone", "0", 0);
  setenv("OSLogRateLimit", "64", 0);
}

int main(int argc, char *argv[]) {
  if (geteuid() == 0) {
    show_error("请从已登录的 macOS 用户会话启动游戏；不支持由 root 直接启动。");
    return 1;
  }

  char self_path[PATH_MAX];
  if (executable_path(self_path, sizeof(self_path)) != 0) {
    show_error("无法确定启动器所在位置。");
    return 1;
  }

  char macos_dir[PATH_MAX];
  if (strlcpy(macos_dir, self_path, sizeof(macos_dir)) >= sizeof(macos_dir)) {
    show_error("启动器路径过长。");
    return 1;
  }
  char *last_slash = strrchr(macos_dir, '/');
  if (last_slash == NULL) {
    show_error("启动器路径无效。");
    return 1;
  }
  *last_slash = '\0';

  char runner_path[PATH_MAX];
  if (join_path(runner_path, sizeof(runner_path), macos_dir,
                "launchIdentityVRunner") != 0 ||
      access(runner_path, X_OK) != 0) {
    show_error("应用内的 launchIdentityVRunner 缺失或不可执行。请重新安装此应用。");
    return 1;
  }

  const char *home = getenv("HOME");
  if (home != NULL && home[0] != '\0') {
    (void)chdir(home);
  }
  set_default_environment();

  const char *product = "mainland";
  if (argc == 3 && strcmp(argv[1], "--product") == 0 &&
      (strcmp(argv[2], "mainland") == 0 || strcmp(argv[2], "global") == 0)) {
    product = argv[2];
  } else if (argc != 1) {
    show_error("启动参数无效。请选择国服或国际服后重试。");
    return 64;
  }
  /* Let the runner detach before Wine starts so this helper App does not own
   * the game's LaunchServices/focus lifecycle. */
  char *const runner_argv[] = {"/bin/zsh", runner_path, "--product",
                               (char *)product, NULL};
  execv("/bin/zsh", runner_argv);
  perror("execv launchIdentityVRunner");
  show_error("无法启动应用内的游戏运行器。请查看启动日志，或重新安装应用。");
  return 127;
}
