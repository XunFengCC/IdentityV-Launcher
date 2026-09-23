#include <stdio.h>
#include <stdlib.h>

static const char *environment_value(const char *name) {
    const char *value = getenv(name);
    return value != NULL ? value : "unset";
}

int main(int argc, char **argv) {
    const char *output_path = getenv("IDENTITYV_ENV_DUMPER_OUTPUT");
    if (output_path == NULL || output_path[0] == '\0') return 64;

    FILE *output = fopen(output_path, "a");
    if (output == NULL) return 1;
    fprintf(output, "enabled=%s menu=%s log=%s fallback=%s args=",
            environment_value("MTL_HUD_ENABLED"),
            environment_value("MTL_HUD_DISABLE_MENU_BAR"),
            environment_value("MTL_HUD_LOG_ENABLED"),
            environment_value("DYLD_FALLBACK_LIBRARY_PATH"));
    for (int index = 1; index < argc; index++) {
        if (index > 1) fputc(' ', output);
        fputs(argv[index], output);
    }
    fputc('\n', output);
    return fclose(output) == 0 ? 0 : 1;
}
