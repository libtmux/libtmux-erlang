# Option catalogue

Generated from pinned tmux `options-table.c` files by
`tools/generate_options.py`. [Scoped options](options.md) defines the
public API. Types describe tmux's parser; values use binary text.
Hooks appear for discovery and are rejected by the option API.

## Sources

| Version | Source | SHA-256 | Entries |
| --- | --- | --- | --- |
| 3.3 | [Table](https://github.com/tmux/tmux/blob/87fe00e8b44901240fc22d7120c1b31e4331f6f5/options-table.c) | `dbf0432e6620735554e798a0aef55c5dd2a1021518261fef4b3f93e60989d2b4` | 181 |
| 3.3a | [Table](https://github.com/tmux/tmux/blob/0b355ae8114511e1ff6359272b164f1cdf718e80/options-table.c) | `dbf0432e6620735554e798a0aef55c5dd2a1021518261fef4b3f93e60989d2b4` | 181 |
| 3.4 | [Table](https://github.com/tmux/tmux/blob/9ae69c3795ab5ef6b4d760f6398cd9281151f632/options-table.c) | `b50f5da4d81dfd26089d35510b96f8f1cf5457d05835d8494feeea0c5cf4e1ea` | 186 |
| 3.5 | [Table](https://github.com/tmux/tmux/blob/ac44566c9c7e3e94d23be6def4c7ae83472543f5/options-table.c) | `b3d678c0f3a52c6cd742fb16b8e57c4e808223e814d88422f7344b7ef5e4bb92` | 190 |
| 3.5a | [Table](https://github.com/tmux/tmux/blob/549c35b06165f6ae023115eb76f83f2cbf945395/options-table.c) | `b3d678c0f3a52c6cd742fb16b8e57c4e808223e814d88422f7344b7ef5e4bb92` | 190 |
| 3.6 | [Table](https://github.com/tmux/tmux/blob/0dac7fe434d029a4f0b819cba8eb7963df291990/options-table.c) | `bede62bb7230e59e81447287179875c8c0a7ff6a1eb6be71f4a35de999ef66b2` | 210 |
| 3.6a | [Table](https://github.com/tmux/tmux/blob/cc117b5048f77a4842820f8ebbe3a86e5c077224/options-table.c) | `bede62bb7230e59e81447287179875c8c0a7ff6a1eb6be71f4a35de999ef66b2` | 210 |
| 3.6b | [Table](https://github.com/tmux/tmux/blob/0623d1e968423ad0c192e0d8debf1258671063d5/options-table.c) | `bede62bb7230e59e81447287179875c8c0a7ff6a1eb6be71f4a35de999ef66b2` | 210 |
| 3.7 | [Table](https://github.com/tmux/tmux/blob/81f88f8517c9fc5371b56cf117530c6b477c96ac/options-table.c) | `c1245a284d540f4c5160617c2f762718b9bc264236c5cf1524b34f51621b56c2` | 221 |
| 3.7a | [Table](https://github.com/tmux/tmux/blob/0e418b62d259ce8da8970f75732cc6632ee4c3a0/options-table.c) | `c1245a284d540f4c5160617c2f762718b9bc264236c5cf1524b34f51621b56c2` | 221 |
| 3.7b | [Table](https://github.com/tmux/tmux/blob/e802909de06012a4df6209d55e86487c56223163/options-table.c) | `c1245a284d540f4c5160617c2f762718b9bc264236c5cf1524b34f51621b56c2` | 221 |
| 3.7c | [Table](https://github.com/tmux/tmux/blob/e476c1230b958df0cb12977517d24b3dc931375b/options-table.c) | `c1245a284d540f4c5160617c2f762718b9bc264236c5cf1524b34f51621b56c2` | 221 |
| 3.8 | [Table](https://github.com/tmux/tmux/blob/7f2a35ad3321f9ba57a1062ca73b1f3ff26aca53/options-table.c) | `cbf3b034785b30aeee3d67032f99e9d9b173a321e11b19be1a11c9e9914fc866` | 272 |

## Options and hooks

| Name | Versions | Scopes | Type | Array | Hook |
| --- | --- | --- | --- | --- | --- |
| `activity-action` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | choice | false | false |
| `after-bind-key` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-capture-pane` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-copy-mode` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-display-message` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-display-panes` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-kill-pane` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-list-buffers` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-list-clients` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-list-keys` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-list-panes` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-list-sessions` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-list-windows` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-load-buffer` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-lock-server` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-new-session` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-new-window` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-paste-buffer` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-pipe-pane` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-queue` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | session | command | true | true |
| `after-refresh-client` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-rename-session` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-rename-window` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-resize-pane` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-resize-window` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-save-buffer` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-select-layout` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-select-pane` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-select-window` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-send-keys` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-set-buffer` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-set-environment` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-set-hook` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-set-option` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-show-environment` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-show-messages` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-show-options` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-split-window` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `after-swap-window` | 3.8 | session | command | true | true |
| `after-unbind-key` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `aggressive-resize` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | flag | false | false |
| `alert-activity` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `alert-bell` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `alert-silence` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `allow-passthrough` | 3.3, 3.3a | window, pane | flag | false | false |
| `allow-passthrough` | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | choice | false | false |
| `allow-rename` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | flag | false | false |
| `allow-set-title` | 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | flag | false | false |
| `alternate-screen` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | flag | false | false |
| `assume-paste-time` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | number | false | false |
| `automatic-rename` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | flag | false | false |
| `automatic-rename-format` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `backspace` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | key | false | false |
| `base-index` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | number | false | false |
| `bell-action` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | choice | false | false |
| `buffer-limit` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | number | false | false |
| `clear-on-attach` | 3.8 | server | flag | false | false |
| `client-active` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `client-attached` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `client-closed` | 3.8 | session | command | true | true |
| `client-created` | 3.8 | session | command | true | true |
| `client-dark-theme` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `client-detached` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `client-focus-in` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `client-focus-out` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `client-light-theme` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `client-resized` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `client-session-changed` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `clock-mode-colour` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | window | colour | false | false |
| `clock-mode-colour` | 3.8 | window | string | false | false |
| `clock-mode-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | choice | false | false |
| `codepoint-widths` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | string | true | false |
| `command-alias` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | string | true | false |
| `command-error` | 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `copy-command` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | string | false | false |
| `copy-mode-current-line-number-style` | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `copy-mode-current-line-style` | 3.8 | window | string | false | false |
| `copy-mode-current-match-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `copy-mode-line-number-style` | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `copy-mode-line-numbers` | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | choice | false | false |
| `copy-mode-mark-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `copy-mode-match-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `copy-mode-position-format` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | string | false | false |
| `copy-mode-position-style` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `copy-mode-selection-style` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `cursor-colour` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | window, pane | colour | false | false |
| `cursor-colour` | 3.8 | window, pane | string | false | false |
| `cursor-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | choice | false | false |
| `dark-theme-black` | 3.8 | server | string | false | false |
| `dark-theme-blue` | 3.8 | server | string | false | false |
| `dark-theme-cyan` | 3.8 | server | string | false | false |
| `dark-theme-dark-grey` | 3.8 | server | string | false | false |
| `dark-theme-green` | 3.8 | server | string | false | false |
| `dark-theme-light-grey` | 3.8 | server | string | false | false |
| `dark-theme-magenta` | 3.8 | server | string | false | false |
| `dark-theme-red` | 3.8 | server | string | false | false |
| `dark-theme-white` | 3.8 | server | string | false | false |
| `dark-theme-yellow` | 3.8 | server | string | false | false |
| `default-client-command` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | command | false | false |
| `default-command` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | string | false | false |
| `default-shell` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | string | false | false |
| `default-size` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | string | false | false |
| `default-terminal` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | string | false | false |
| `destroy-unattached` | 3.3, 3.3a | session | flag | false | false |
| `destroy-unattached` | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | choice | false | false |
| `detach-on-destroy` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | choice | false | false |
| `display-panes-active-colour` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | session | colour | false | false |
| `display-panes-active-colour` | 3.8 | window | string | false | false |
| `display-panes-border-style` | 3.8 | window | string | false | false |
| `display-panes-colour` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | session | colour | false | false |
| `display-panes-colour` | 3.8 | window | string | false | false |
| `display-panes-format` | 3.8 | window | string | false | false |
| `display-panes-time` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | session | number | false | false |
| `display-panes-time` | 3.8 | window | number | false | false |
| `display-time` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | number | false | false |
| `editor` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | string | false | false |
| `escape-time` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | number | false | false |
| `exit-empty` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | flag | false | false |
| `exit-unattached` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | flag | false | false |
| `extended-keys` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | choice | false | false |
| `extended-keys-format` | 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | choice | false | false |
| `fill-character` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `focus-events` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | flag | false | false |
| `focus-follows-mouse` | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | flag | false | false |
| `get-clipboard` | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | choice | false | false |
| `history-file` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | string | false | false |
| `history-limit` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | number | false | false |
| `initial-repeat-time` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | number | false | false |
| `input-buffer-size` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | number | false | false |
| `key-table` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | string | false | false |
| `light-theme-black` | 3.8 | server | string | false | false |
| `light-theme-blue` | 3.8 | server | string | false | false |
| `light-theme-cyan` | 3.8 | server | string | false | false |
| `light-theme-dark-grey` | 3.8 | server | string | false | false |
| `light-theme-green` | 3.8 | server | string | false | false |
| `light-theme-light-grey` | 3.8 | server | string | false | false |
| `light-theme-magenta` | 3.8 | server | string | false | false |
| `light-theme-red` | 3.8 | server | string | false | false |
| `light-theme-white` | 3.8 | server | string | false | false |
| `light-theme-yellow` | 3.8 | server | string | false | false |
| `lock-after-time` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | number | false | false |
| `lock-command` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | string | false | false |
| `main-pane-height` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `main-pane-width` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `marked-pane-changed` | 3.8 | session | command | true | true |
| `menu-border-lines` | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | choice | false | false |
| `menu-border-style` | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `menu-selected-style` | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `menu-style` | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `message-command-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | string | false | false |
| `message-format` | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | string | false | false |
| `message-limit` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | number | false | false |
| `message-line` | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | choice | false | false |
| `message-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | string | false | false |
| `mode-keys` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | choice | false | false |
| `mode-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `monitor-activity` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | flag | false | false |
| `monitor-bell` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | flag | false | false |
| `monitor-silence` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | number | false | false |
| `mouse` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | flag | false | false |
| `other-pane-height` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `other-pane-width` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `pane-active-border-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b | window | string | false | false |
| `pane-active-border-style` | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | string | false | false |
| `pane-activity` | 3.8 | window, pane | command | true | true |
| `pane-base-index` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | number | false | false |
| `pane-bell` | 3.8 | window, pane | command | true | true |
| `pane-border-format` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | string | false | false |
| `pane-border-indicators` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | choice | false | false |
| `pane-border-lines` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | window | choice | false | false |
| `pane-border-lines` | 3.8 | window, pane | choice | false | false |
| `pane-border-status` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | window | choice | false | false |
| `pane-border-status` | 3.8 | window, pane | choice | false | false |
| `pane-border-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b | window | string | false | false |
| `pane-border-style` | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | string | false | false |
| `pane-colours` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | colour | true | false |
| `pane-command-finished` | 3.8 | window, pane | command | true | true |
| `pane-command-started` | 3.8 | window, pane | command | true | true |
| `pane-created` | 3.8 | window, pane | command | true | true |
| `pane-died` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | command | true | true |
| `pane-exited` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | command | true | true |
| `pane-focus-in` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | command | true | true |
| `pane-focus-out` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | command | true | true |
| `pane-mode-changed` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | command | true | true |
| `pane-mode-entered` | 3.8 | window, pane | command | true | true |
| `pane-mode-exited` | 3.8 | window, pane | command | true | true |
| `pane-moved` | 3.8 | window, pane | command | true | true |
| `pane-prompt-closed` | 3.8 | window, pane | command | true | true |
| `pane-prompt-opened` | 3.8 | window, pane | command | true | true |
| `pane-resized` | 3.8 | window, pane | command | true | true |
| `pane-scrollbars` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | choice | false | false |
| `pane-scrollbars-position` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | choice | false | false |
| `pane-scrollbars-style` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | string | false | false |
| `pane-scrollbars-timeout` | 3.8 | window | number | false | false |
| `pane-set-clipboard` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | command | true | true |
| `pane-shell-prompt` | 3.8 | window, pane | command | true | true |
| `pane-status-current-style` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `pane-status-style` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `pane-title-changed` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | command | true | true |
| `popup-border-lines` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | choice | false | false |
| `popup-border-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `popup-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `prefix` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | key | false | false |
| `prefix-timeout` | 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | number | false | false |
| `prefix2` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | key | false | false |
| `prompt-command-cursor-colour` | 3.8 | session | string | false | false |
| `prompt-command-cursor-style` | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | choice | false | false |
| `prompt-cursor-colour` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c | session | colour | false | false |
| `prompt-cursor-colour` | 3.8 | session | string | false | false |
| `prompt-cursor-style` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | choice | false | false |
| `prompt-history-limit` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | number | false | false |
| `remain-on-exit` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | choice | false | false |
| `remain-on-exit-format` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | string | false | false |
| `renumber-windows` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | flag | false | false |
| `repeat-time` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | number | false | false |
| `scroll-on-clear` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | flag | false | false |
| `session-added-to-group` | 3.8 | session | command | true | true |
| `session-closed` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `session-created` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `session-removed-from-group` | 3.8 | session | command | true | true |
| `session-renamed` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `session-status-current-style` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `session-status-style` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `session-window-changed` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `set-clipboard` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | choice | false | false |
| `set-titles` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | flag | false | false |
| `set-titles-string` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | string | false | false |
| `silence-action` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | choice | false | false |
| `status` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | choice | false | false |
| `status-bg` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | colour | false | false |
| `status-fg` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | colour | false | false |
| `status-format` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | string | true | false |
| `status-interval` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | number | false | false |
| `status-justify` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | choice | false | false |
| `status-keys` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | choice | false | false |
| `status-left` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | string | false | false |
| `status-left-length` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | number | false | false |
| `status-left-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | string | false | false |
| `status-position` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | choice | false | false |
| `status-right` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | string | false | false |
| `status-right-length` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | number | false | false |
| `status-right-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | string | false | false |
| `status-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | string | false | false |
| `switch-mode-match-style` | 3.8 | window, pane | string | false | false |
| `synchronize-panes` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | flag | false | false |
| `terminal-features` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | string | true | false |
| `terminal-overrides` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | string | true | false |
| `theme` | 3.8 | server | choice | false | false |
| `tiled-layout-max-columns` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | number | false | false |
| `tree-mode-border-style` | 3.8 | window | string | false | false |
| `tree-mode-preview-format` | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | string | false | false |
| `tree-mode-preview-style` | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `tree-mode-selection-style` | 3.8 | window | string | false | false |
| `update-environment` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | string | true | false |
| `user-keys` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | string | true | false |
| `variation-selector-always-wide` | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | server | flag | false | false |
| `visual-activity` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | choice | false | false |
| `visual-bell` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | choice | false | false |
| `visual-silence` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | choice | false | false |
| `window-active-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | string | false | false |
| `window-closed` | 3.8 | window | command | true | true |
| `window-created` | 3.8 | window | command | true | true |
| `window-layout-changed` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | command | true | true |
| `window-linked` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `window-pane-changed` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | command | true | true |
| `window-pane-current-status-format` | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `window-pane-status-format` | 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `window-renamed` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | command | true | true |
| `window-resized` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | command | true | true |
| `window-size` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | choice | false | false |
| `window-status-activity-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `window-status-bell-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `window-status-current-format` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `window-status-current-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `window-status-format` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `window-status-last-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `window-status-separator` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `window-status-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | string | false | false |
| `window-style` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window, pane | string | false | false |
| `window-unlinked` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | command | true | true |
| `window-unzoomed` | 3.8 | window | command | true | true |
| `window-zoomed` | 3.8 | window | command | true | true |
| `word-separators` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | session | string | false | false |
| `wrap-search` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | flag | false | false |
| `xterm-keys` | 3.3, 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 | window | flag | false | false |
