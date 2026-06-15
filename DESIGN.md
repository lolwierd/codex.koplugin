# Codex Chat Viewer

The chat should feel like another reading surface, not a terminal or a web panel.

- KOReader's active text-viewer font and size are reused.
- The transcript fills the available reading area using KOReader's own line wrapping.
- Page boundaries are measured with KOReader's `TextViewer`, then each page is shown
  as a fresh native viewer. Visible text widgets are never mutated after layout.
- Previous/Next buttons replace the current page using the same close/show lifecycle
  as KOReader's built-in paged detail views.
- Conversation actions stay visible below the reading surface: Reply, History, and
  New chat.
