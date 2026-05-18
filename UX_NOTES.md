# UX Notes

Purpose: Preserve current UX direction and avoid losing context between sessions.

## Channel Interaction Rules

- Selecting a channel must trigger join automatically.
- Chat history may load immediately, but message composer should remain disabled until join acknowledgement arrives.
- Show explicit joining state in the input placeholder ("Joining channel...").
- Do not silently rejoin on send; join should be state-driven by channel selection.

## Explorer-First Navigation

- Keep a tree-based explorer as primary navigation.
- Support filter modes:
  - All
  - Only Files
  - Only Terminals
  - Only Channels
- Keep quick text filter for tree nodes.

## Modern UI Directions (Candidates)

### 1) Command Palette + Tree Hybrid

- Left explorer tree stays primary.
- Add command palette (Ctrl/Cmd+K style) for fast jumps:
  - Open file
  - Join channel
  - Focus terminal
- Best for power users without losing discoverability.

### 2) Context Dock Layout

- Explorer on left, main content center, contextual dock on right.
- Right dock swaps content by active item:
  - channel members
  - terminal session metadata
  - file symbol outline
- Modern feel with strong information scent.

### 3) Activity Rail + Smart Tree

- Add thin activity rail for major modes (Project, Chat, Terminal, Presence).
- Tree adapts to selected mode but keeps hierarchy and filters.
- Cleaner than tab stacks while still mode-oriented.

### 4) Multiplayer Presence Layer

- Persistent presence strip: who is in which pane/item.
- Optional soft follow indicator (following, followed by, detached).
- Cursor and viewport cues only when relevant; avoid constant animation.

## Follow-Along UX Recommendations

- Three follow states:
  - Off
  - Soft Follow (file/item sync, non-forced scroll)
  - Hard Follow (full viewport sync)
- Add "Recenter on Host" and "Detach" actions.
- Respect local edit intent: do not steal focus while user is typing.

## Pane Presets

Preconfigured layouts are still valid:

- 1 big
- split horizontal
- split vertical
- split horizontal + top split vertical
- split vertical + left split horizontal
- quads

Modernization add-ons:

- "Focus pane" action (temporary maximize)
- one-click restore previous layout
- per-project remembered layout
