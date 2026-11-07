# Fields and relationships

Generated from the compiled schema and operator validator. Do not edit
the tables by hand. Field names on the left are Erlang atoms; wire names
are JSON strings. IDs are strings, never numbers.

Text is case-sensitive UTF-8. Bytes use a single-key base64 object on the
wire. Nullable values use `none` locally and `null` on the wire.
`not_loaded` and `unavailable` are coverage states, not null values.

## session

| Field | Wire name | Type | Nullable | Operators |
| --- | --- | --- | --- | --- |
| `id` | `id` | `session_id` | false | `equals`, `'not'`, `in`, `not_in` |
| `attached` | `attached` | `boolean` | false | `equals`, `'not'`, `in`, `not_in` |
| `attached_count` | `attachedCount` | `uint` | false | `equals`, `'not'`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `created` | `created` | `uint` | false | `equals`, `'not'`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `name` | `name` | `text` | false | `equals`, `'not'`, `in`, `not_in`, `contains`, `starts_with`, `ends_with`, `regex` |

| Relationship | Wire name | Target | Cardinality |
| --- | --- | --- | --- |
| `window_links` | `windowLinks` | `window_link` | many |
| `windows` | `windows` | `window` | many |

## window

| Field | Wire name | Type | Nullable | Operators |
| --- | --- | --- | --- | --- |
| `id` | `id` | `window_id` | false | `equals`, `'not'`, `in`, `not_in` |
| `height` | `height` | `uint` | false | `equals`, `'not'`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `layout` | `layout` | `text` | false | `equals`, `'not'`, `in`, `not_in`, `contains`, `starts_with`, `ends_with`, `regex` |
| `name` | `name` | `text` | false | `equals`, `'not'`, `in`, `not_in`, `contains`, `starts_with`, `ends_with`, `regex` |
| `pane_count` | `paneCount` | `uint` | false | `equals`, `'not'`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `width` | `width` | `uint` | false | `equals`, `'not'`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |

| Relationship | Wire name | Target | Cardinality |
| --- | --- | --- | --- |
| `panes` | `panes` | `pane` | many |
| `window_links` | `windowLinks` | `window_link` | many |

## window_link

| Field | Wire name | Type | Nullable | Operators |
| --- | --- | --- | --- | --- |
| `index` | `index` | `uint` | false | `equals`, `'not'`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `session_id` | `sessionId` | `session_id` | false | `equals`, `'not'`, `in`, `not_in` |
| `window_id` | `windowId` | `window_id` | false | `equals`, `'not'`, `in`, `not_in` |
| `active` | `active` | `boolean` | false | `equals`, `'not'`, `in`, `not_in` |

| Relationship | Wire name | Target | Cardinality |
| --- | --- | --- | --- |
| `session` | `session` | `session` | one |
| `window` | `window` | `window` | one |

## pane

| Field | Wire name | Type | Nullable | Operators |
| --- | --- | --- | --- | --- |
| `id` | `id` | `pane_id` | false | `equals`, `'not'`, `in`, `not_in` |
| `active` | `active` | `boolean` | false | `equals`, `'not'`, `in`, `not_in` |
| `current_command` | `currentCommand` | `text` | false | `equals`, `'not'`, `in`, `not_in`, `contains`, `starts_with`, `ends_with`, `regex` |
| `current_path` | `currentPath` | `bytes` | false | `equals`, `'not'`, `in`, `not_in`, `contains`, `starts_with`, `ends_with` |
| `dead` | `dead` | `boolean` | false | `equals`, `'not'`, `in`, `not_in` |
| `exit_status` | `exitStatus` | `integer` | true | `equals`, `'not'`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte`, `present` |
| `height` | `height` | `uint` | false | `equals`, `'not'`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `index` | `index` | `uint` | false | `equals`, `'not'`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `pid` | `pid` | `uint` | true | `equals`, `'not'`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte`, `present` |
| `title` | `title` | `text` | false | `equals`, `'not'`, `in`, `not_in`, `contains`, `starts_with`, `ends_with`, `regex` |
| `width` | `width` | `uint` | false | `equals`, `'not'`, `in`, `not_in`, `lt`, `lte`, `gt`, `gte` |
| `window_id` | `windowId` | `window_id` | false | `equals`, `'not'`, `in`, `not_in` |

| Relationship | Wire name | Target | Cardinality |
| --- | --- | --- | --- |
| `window` | `window` | `window` | one |
