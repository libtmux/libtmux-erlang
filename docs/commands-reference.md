# Native commands and capability floors

Generated from pinned tmux source profiles. These are native
parser declarations, not an inventory of implemented Erlang facades,
complete argument validation or runtime qualification. Canonical names
are lookup keys; aliases are reported as metadata. The
`m:tmux_capability` performs pure lookups. Trusted raw commands remain
available through `tmux_command:raw/2`.

## Capability minimums

Capability minimums name the earliest catalogued source profile for
each feature. Runtime support covers tmux 3.3a–3.8, including
intermediate releases. Routine CI samples only 3.3a and 3.8 on both
supported architectures. See
[compatibility](compatibility.md) for platform and API qualification.

| Capability | Minimum tmux | Native behavior |
| --- | --- | --- |
| `key_list_format` | 3.7 | Native list-keys -F custom formatting. |
| `layout_json` | 3.8 | Native JSON layout parsing, including the v2 layout representation. |
| `native_list_filter` | 3.3 | Native -f filters on session, window and pane list commands. |
| `send_client_keys` | 3.4 | Native send-keys -K and -c for client-directed key input. |

## Source profiles

Exact parser discovery uses the profiles below. The 3.3 profile is
retained as upstream history; the library's runtime floor is 3.3a.

| Profile | Pinned command table | Commands |
| --- | --- | --- |
| 3.3 | [Source](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/cmd.c) | 90 |
| 3.3a | [Source](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/cmd.c) | 90 |
| 3.4 | [Source](https://github.com/tmux/tmux/blob/9ae69c3795ab5ef6b4d760f6398cd9281151f632/cmd.c) | 90 |
| 3.5 | [Source](https://github.com/tmux/tmux/blob/ac44566c9c7e3e94d23be6def4c7ae83472543f5/cmd.c) | 90 |
| 3.5a | [Source](https://github.com/tmux/tmux/blob/549c35b06165f6ae023115eb76f83f2cbf945395/cmd.c) | 90 |
| 3.6 | [Source](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/cmd.c) | 90 |
| 3.6a | [Source](https://github.com/tmux/tmux/blob/cc117b5048f77a4842820f8ebbe3a86e5c077224/cmd.c) | 90 |
| 3.6b | [Source](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/cmd.c) | 90 |
| 3.7 | [Source](https://github.com/tmux/tmux/blob/81f88f8517c9fc5371b56cf117530c6b477c96ac/cmd.c) | 91 |
| 3.7a | [Source](https://github.com/tmux/tmux/blob/0e418b62d259ce8da8970f75732cc6632ee4c3a0/cmd.c) | 91 |
| 3.7b | [Source](https://github.com/tmux/tmux/blob/e802909de06012a4df6209d55e86487c56223163/cmd.c) | 91 |
| 3.7c | [Source](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd.c) | 91 |
| 3.8 | [Source](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd.c) | 92 |

## Parser declarations

The argument spec is tmux's native flag declaration. Positional bounds
exclude flags; an unlimited upper bound is shown as unbounded. Callbacks
and command bodies can impose additional constraints. This catalogue
does not interpret formats, shell commands or stored command syntax.

| Command | Alias | Profiles | Argument spec | Positionals | Source |
| --- | --- | --- | --- | --- | --- |
| `attach-session` | attach | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `c:dEf:rt:x` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-attach-session.c) |
| `bind-key` | bind | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `nrN:T:` | 1..unbounded | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-bind-key.c) |
| `break-pane` | breakp | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `abdPF:n:s:t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-break-pane.c) |
| `break-pane` | breakp | 3.8 | `abdPF:n:s:t:Wx:X:y:Y:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-break-pane.c) |
| `capture-pane` | capturep | 3.3, 3.3a | `ab:CeE:JNpPqS:t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/cmd-capture-pane.c) |
| `capture-pane` | capturep | 3.4, 3.5, 3.5a | `ab:CeE:JNpPqS:Tt:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/549c35b06165f6ae023115eb76f83f2cbf945395/cmd-capture-pane.c) |
| `capture-pane` | capturep | 3.6, 3.6a, 3.6b | `ab:CeE:JMNpPqS:Tt:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/cmd-capture-pane.c) |
| `capture-pane` | capturep | 3.7, 3.7a, 3.7b, 3.7c | `ab:CeE:FHJLMNpPqS:Tt:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-capture-pane.c) |
| `capture-pane` | capturep | 3.8 | `ab:CeE:FHIJLMNpPqRS:Tt:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-capture-pane.c) |
| `choose-buffer` | — | 3.3, 3.3a, 3.4, 3.5, 3.5a | `F:f:K:NO:rt:Z` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/549c35b06165f6ae023115eb76f83f2cbf945395/cmd-choose-tree.c) |
| `choose-buffer` | — | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `F:f:K:NO:rt:yZ` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-choose-tree.c) |
| `choose-buffer` | — | 3.8 | `F:f:K:kNO:rt:yZ` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-choose-tree.c) |
| `choose-client` | — | 3.3, 3.3a, 3.4, 3.5, 3.5a | `F:f:K:NO:rt:Z` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/549c35b06165f6ae023115eb76f83f2cbf945395/cmd-choose-tree.c) |
| `choose-client` | — | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `F:f:K:NO:rt:yZ` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-choose-tree.c) |
| `choose-client` | — | 3.8 | `F:f:hiK:kNO:rt:yZ` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-choose-tree.c) |
| `choose-tree` | — | 3.3, 3.3a, 3.4, 3.5, 3.5a | `F:f:GK:NO:rst:wZ` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/549c35b06165f6ae023115eb76f83f2cbf945395/cmd-choose-tree.c) |
| `choose-tree` | — | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `F:f:GK:NO:rst:wyZ` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-choose-tree.c) |
| `choose-tree` | — | 3.8 | `F:f:GhK:kNO:rst:wyZ` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-choose-tree.c) |
| `clear-history` | clearhist | 3.3, 3.3a | `t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/cmd-capture-pane.c) |
| `clear-history` | clearhist | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `Ht:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-capture-pane.c) |
| `clear-prompt-history` | clearphist | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `T:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-show-prompt-history.c) |
| `clock-mode` | — | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-copy-mode.c) |
| `command-prompt` | — | 3.3, 3.3a, 3.4, 3.5, 3.5a | `1bFkiI:Np:t:T:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/549c35b06165f6ae023115eb76f83f2cbf945395/cmd-command-prompt.c) |
| `command-prompt` | — | 3.6, 3.6a, 3.6b | `1bFkliI:Np:t:T:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/cmd-command-prompt.c) |
| `command-prompt` | — | 3.7, 3.7a, 3.7b, 3.7c | `1CbeFiklI:Np:t:T:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-command-prompt.c) |
| `command-prompt` | — | 3.8 | `1CbeFiklI:NPp:t:T:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-command-prompt.c) |
| `confirm-before` | confirm | 3.3, 3.3a | `bp:t:` | 1..1 | [Declaration](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/cmd-confirm-before.c) |
| `confirm-before` | confirm | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `bc:p:t:y` | 1..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-confirm-before.c) |
| `copy-mode` | — | 3.3, 3.3a, 3.4 | `eHMs:t:uq` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/9ae69c3795ab5ef6b4d760f6398cd9281151f632/cmd-copy-mode.c) |
| `copy-mode` | — | 3.5, 3.5a | `deHMs:t:uq` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/549c35b06165f6ae023115eb76f83f2cbf945395/cmd-copy-mode.c) |
| `copy-mode` | — | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `deHMqSs:t:u` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-copy-mode.c) |
| `copy-mode` | — | 3.8 | `dekHMqSs:t:u` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-copy-mode.c) |
| `customize-mode` | — | 3.3, 3.3a, 3.4, 3.5, 3.5a | `F:f:Nt:Z` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/549c35b06165f6ae023115eb76f83f2cbf945395/cmd-choose-tree.c) |
| `customize-mode` | — | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `F:f:Nt:yZ` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-choose-tree.c) |
| `customize-mode` | — | 3.8 | `F:f:kNt:yZ` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-choose-tree.c) |
| `delete-buffer` | deleteb | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `b:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-set-buffer.c) |
| `detach-client` | detach | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `aE:s:t:P` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-detach-client.c) |
| `display-menu` | menu | 3.3, 3.3a | `c:t:OT:x:y:` | 1..unbounded | [Declaration](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/cmd-display-menu.c) |
| `display-menu` | menu | 3.4 | `b:c:C:H:s:S:Ot:T:x:y:` | 1..unbounded | [Declaration](https://github.com/tmux/tmux/blob/9ae69c3795ab5ef6b4d760f6398cd9281151f632/cmd-display-menu.c) |
| `display-menu` | menu | 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `b:c:C:H:s:S:MOt:T:x:y:` | 1..unbounded | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-display-menu.c) |
| `display-message` | display | 3.3, 3.3a | `ac:d:INpt:F:v` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/cmd-display-message.c) |
| `display-message` | display | 3.4, 3.5, 3.5a | `ac:d:lINpt:F:v` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/549c35b06165f6ae023115eb76f83f2cbf945395/cmd-display-message.c) |
| `display-message` | display | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `aCc:d:lINpt:F:v` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-display-message.c) |
| `display-message` | display | 3.8 | `aCc:d:jlINpt:F:v` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-display-message.c) |
| `display-panes` | displayp | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `bd:Nt:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-display-panes.c) |
| `display-panes` | displayp | 3.8 | `d:kNs:t:Z` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-choose-tree.c) |
| `display-popup` | popup | 3.3, 3.3a, 3.4, 3.5, 3.5a | `Bb:Cc:d:e:Eh:s:S:t:T:w:x:y:` | 0..unbounded | [Declaration](https://github.com/tmux/tmux/blob/549c35b06165f6ae023115eb76f83f2cbf945395/cmd-display-menu.c) |
| `display-popup` | popup | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `Bb:Cc:d:e:Eh:kNs:S:t:T:w:x:y:` | 0..unbounded | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-display-menu.c) |
| `find-window` | findw | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `CiNrt:TZ` | 1..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-find-window.c) |
| `has-session` | has | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-new-session.c) |
| `if-shell` | if | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `bFt:` | 2..3 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-if-shell.c) |
| `join-pane` | joinp | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `bdfhvp:l:s:t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-join-pane.c) |
| `kill-pane` | killp | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `at:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-kill-pane.c) |
| `kill-pane` | killp | 3.8 | `af:t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-kill-pane.c) |
| `kill-server` | — | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-kill-server.c) |
| `kill-session` | — | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b | `aCt:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/cmd-kill-session.c) |
| `kill-session` | — | 3.7, 3.7a, 3.7b, 3.7c | `aCgt:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-kill-session.c) |
| `kill-session` | — | 3.8 | `aCgf:t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-kill-session.c) |
| `kill-window` | killw | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `at:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-kill-window.c) |
| `kill-window` | killw | 3.8 | `af:t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-kill-window.c) |
| `last-pane` | lastp | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `det:Z` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-select-pane.c) |
| `last-window` | last | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-select-window.c) |
| `link-window` | linkw | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `abdks:t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-move-window.c) |
| `list-buffers` | lsb | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b | `F:f:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/cmd-list-buffers.c) |
| `list-buffers` | lsb | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `F:f:O:r` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-list-buffers.c) |
| `list-clients` | lsc | 3.3, 3.3a | `F:t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/cmd-list-clients.c) |
| `list-clients` | lsc | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b | `F:f:t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/cmd-list-clients.c) |
| `list-clients` | lsc | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `F:f:O:rt:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-list-clients.c) |
| `list-commands` | lscm | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b | `F:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/cmd-list-keys.c) |
| `list-commands` | lscm | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `F:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-list-commands.c) |
| `list-keys` | lsk | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b | `1aNP:T:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/cmd-list-keys.c) |
| `list-keys` | lsk | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `1aF:NO:P:rT:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-list-keys.c) |
| `list-panes` | lsp | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b | `asF:f:t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/cmd-list-panes.c) |
| `list-panes` | lsp | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `aF:f:O:rst:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-list-panes.c) |
| `list-sessions` | ls | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b | `F:f:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/cmd-list-sessions.c) |
| `list-sessions` | ls | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `F:f:O:r` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-list-sessions.c) |
| `list-windows` | lsw | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b | `F:f:at:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/cmd-list-windows.c) |
| `list-windows` | lsw | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `aF:f:O:rt:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-list-windows.c) |
| `load-buffer` | loadb | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `b:t:w` | 1..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-load-buffer.c) |
| `lock-client` | lockc | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-lock-server.c) |
| `lock-server` | lock | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-lock-server.c) |
| `lock-session` | locks | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-lock-server.c) |
| `move-pane` | movep | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `bdfhvp:l:s:t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-join-pane.c) |
| `move-pane` | movep | 3.8 | `bdD::fhMvl:L::P:R::s:t:U::X:Y:z:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-join-pane.c) |
| `move-window` | movew | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `abdkrs:t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-move-window.c) |
| `new-pane` | newp | 3.7, 3.7a, 3.7b, 3.7c | `bc:de:EfF:hIkl:Lm:p:PR:s:S:t:vx:X:y:Y:Z` | 0..unbounded | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-split-window.c) |
| `new-pane` | newp | 3.8 | `AbB:Cc:Dde:EfF:hIkl:KLMm:Op:PR:s:S:t:T:vWx:X:y:Y:Z` | 0..unbounded | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-split-window.c) |
| `new-session` | new | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `Ac:dDe:EF:f:n:Ps:t:x:Xy:` | 0..unbounded | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-new-session.c) |
| `new-window` | neww | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `abc:de:F:kn:PSt:` | 0..unbounded | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-new-window.c) |
| `new-window` | neww | 3.8 | `abc:de:EF:kn:PSt:` | 0..unbounded | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-new-window.c) |
| `next-layout` | nextl | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-select-layout.c) |
| `next-window` | next | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `at:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-select-window.c) |
| `paste-buffer` | pasteb | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b | `db:prs:t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/cmd-paste-buffer.c) |
| `paste-buffer` | pasteb | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `db:prSs:t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-paste-buffer.c) |
| `pipe-pane` | pipep | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `IOot:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-pipe-pane.c) |
| `previous-layout` | prevl | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-select-layout.c) |
| `previous-window` | prev | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `at:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-select-window.c) |
| `refresh-client` | refresh | 3.3, 3.3a, 3.4 | `A:B:cC:Df:F:l::LRSt:U` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/9ae69c3795ab5ef6b4d760f6398cd9281151f632/cmd-refresh-client.c) |
| `refresh-client` | refresh | 3.5, 3.5a, 3.6, 3.6a, 3.6b | `A:B:cC:Df:r:F:l::LRSt:U` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/cmd-refresh-client.c) |
| `refresh-client` | refresh | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `A:B:cC:Df:r:F:lLRSt:U` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-refresh-client.c) |
| `rename-session` | rename | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `t:` | 1..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-rename-session.c) |
| `rename-window` | renamew | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `t:` | 1..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-rename-window.c) |
| `resize-pane` | resizep | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `DLMRTt:Ux:y:Z` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-resize-pane.c) |
| `resize-pane` | resizep | 3.8 | `D::L::MR::Tt:U::x:y:Z` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-resize-pane.c) |
| `resize-window` | resizew | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `aADLRt:Ux:y:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-resize-window.c) |
| `respawn-pane` | respawnp | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `c:e:kt:` | 0..unbounded | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-respawn-pane.c) |
| `respawn-pane` | respawnp | 3.8 | `c:e:Ekt:` | 0..unbounded | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-respawn-pane.c) |
| `respawn-window` | respawnw | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `c:e:kt:` | 0..unbounded | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-respawn-window.c) |
| `respawn-window` | respawnw | 3.8 | `c:e:Ekt:` | 0..unbounded | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-respawn-window.c) |
| `rotate-window` | rotatew | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `Dt:UZ` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-rotate-window.c) |
| `run-shell` | run | 3.3, 3.3a | `bd:Ct:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/cmd-run-shell.c) |
| `run-shell` | run | 3.4, 3.5, 3.5a | `bd:Ct:c:` | 0..2 | [Declaration](https://github.com/tmux/tmux/blob/549c35b06165f6ae023115eb76f83f2cbf945395/cmd-run-shell.c) |
| `run-shell` | run | 3.6, 3.6a, 3.6b | `bd:Ct:Es:c:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/cmd-run-shell.c) |
| `run-shell` | run | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `bd:Ct:Es:c:` | 0..unbounded | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-run-shell.c) |
| `save-buffer` | saveb | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `ab:` | 1..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-save-buffer.c) |
| `select-layout` | selectl | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `Enopt:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-select-layout.c) |
| `select-pane` | selectp | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `DdegLlMmP:RT:t:UZ` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-select-pane.c) |
| `select-window` | selectw | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `lnpTt:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-select-window.c) |
| `send-keys` | send | 3.3, 3.3a | `FHlMN:Rt:X` | 0..unbounded | [Declaration](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/cmd-send-keys.c) |
| `send-keys` | send | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `c:FHKlMN:Rt:X` | 0..unbounded | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-send-keys.c) |
| `send-prefix` | — | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `2t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-send-keys.c) |
| `server-access` | — | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `adlrw` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-server-access.c) |
| `server-access` | — | 3.8 | `adglrw` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-server-access.c) |
| `set-buffer` | setb | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `ab:t:n:w` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-set-buffer.c) |
| `set-environment` | setenv | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `Fhgrt:u` | 1..2 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-set-environment.c) |
| `set-hook` | — | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `agpRt:uw` | 1..2 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-set-option.c) |
| `set-hook` | — | 3.8 | `agpERTt:uB:w` | 0..2 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-set-option.c) |
| `set-option` | set | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `aFgopqst:uUw` | 1..2 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-set-option.c) |
| `set-window-option` | setw | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `aFgoqt:u` | 1..2 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-set-option.c) |
| `show-buffer` | showb | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `b:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-save-buffer.c) |
| `show-environment` | showenv | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `hgst:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-show-environment.c) |
| `show-hooks` | — | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `gpt:w` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-show-options.c) |
| `show-hooks` | — | 3.8 | `BF:gpt:w` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-show-options.c) |
| `show-messages` | showmsgs | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `JTt:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-show-messages.c) |
| `show-options` | show | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `AgHpqst:vw` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-show-options.c) |
| `show-options` | show | 3.8 | `AgF:Hpqst:vw` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-show-options.c) |
| `show-prompt-history` | showphist | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `T:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-show-prompt-history.c) |
| `show-window-options` | showw | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `gvt:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-show-options.c) |
| `show-window-options` | showw | 3.8 | `F:gvt:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-show-options.c) |
| `source-file` | source | 3.3, 3.3a | `Fnqv` | 1..unbounded | [Declaration](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/cmd-source-file.c) |
| `source-file` | source | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `t:Fnqv` | 1..unbounded | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-source-file.c) |
| `split-window` | splitw | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b | `bc:de:fF:hIl:p:Pt:vZ` | 0..unbounded | [Declaration](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/cmd-split-window.c) |
| `split-window` | splitw | 3.7, 3.7a, 3.7b, 3.7c | `bc:de:EfF:hIkl:m:p:PR:s:S:t:vZ` | 0..unbounded | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-split-window.c) |
| `split-window` | splitw | 3.8 | `bB:c:de:EfF:hIkl:m:p:PR:s:S:t:T:vWZ` | 0..unbounded | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-split-window.c) |
| `start-server` | start | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-kill-server.c) |
| `suspend-client` | suspendc | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-detach-client.c) |
| `swap-pane` | swapp | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `dDs:t:UZ` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-swap-pane.c) |
| `swap-window` | swapw | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `ds:t:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-swap-window.c) |
| `switch-client` | switchc | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b | `lc:EFnpt:rT:Z` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/cmd-switch-client.c) |
| `switch-client` | switchc | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `c:EFlnO:pt:rT:Z` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-switch-client.c) |
| `switch-mode` | — | 3.8 | `F:kst:wZ` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-choose-tree.c) |
| `unbind-key` | unbind | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `anqT:` | 0..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-unbind-key.c) |
| `unlink-window` | unlinkw | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | `kt:` | 0..0 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-kill-window.c) |
| `wait-for` | wait | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | `LSU` | 1..1 | [Declaration](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/cmd-wait-for.c) |
| `wait-for` | wait | 3.8 | `EF:LSUlvw:` | 1..1 | [Declaration](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/cmd-wait-for.c) |
