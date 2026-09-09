#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <xkbcommon/xkbcommon.h>

int main(void) {
    const char *keymap =
        "xkb_keymap {"
        "xkb_keycodes \"probe\" { minimum=8; maximum=255; <AC01>=38; };"
        "xkb_types \"probe\" { type \"ONE_LEVEL\" { modifiers=None; level_name[Level1]=\"Any\"; }; };"
        "xkb_compatibility \"probe\" {};"
        "xkb_symbols \"probe\" { key <AC01> { type=\"ONE_LEVEL\", [ a ] }; };"
        "};";
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_DEFAULT_INCLUDES);
    assert(context);
    struct xkb_keymap *map = xkb_keymap_new_from_string(context, keymap,
        XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
    assert(map);
    struct xkb_state *state = xkb_state_new(map);
    assert(state);
    char output[8] = {0};
    assert(xkb_state_key_get_utf8(state, 38, output, sizeof(output)) == 1);
    assert(strcmp(output, "a") == 0);
    assert(xkb_state_key_get_one_sym(state, 38) == 0x61);
    xkb_state_update_key(state, 38, XKB_KEY_DOWN);
    assert(xkb_state_key_get_utf32(state, 38) == 0x61);
    xkb_state_update_key(state, 38, XKB_KEY_UP);
    xkb_state_unref(state);
    xkb_keymap_unref(map);
    xkb_context_unref(context);
    puts("PASS: candidate compiled and translated a self-contained keyboard map");
    return 0;
}
