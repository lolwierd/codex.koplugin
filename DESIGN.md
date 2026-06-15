# Codex Chat Viewer

The chat should feel like another reading surface, not a terminal or a web panel.

- KOReader's active text-viewer font and size are reused.
- The transcript fills the available reading area using KOReader's own line wrapping.
- Page navigation is explicit and deterministic because `ScrollTextWidget` renders
  blank after scrolling on the target Kobo Libra Colour.
- The viewer contains no scrollbar. Previous/Next buttons and horizontal or vertical
  swipes move by one screen of wrapped lines.
- Conversation actions stay visible below the reading surface: Reply, History, and
  New chat.
