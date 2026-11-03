# baud's design system

This is the one set of numbers and rules the Mac and iPhone apps are built from. It covers the
design tokens, how things behave under a pointer, a finger and a keyboard, and then the changes
to each screen, tied to the problems in [`audit.md`](audit.md).

The aim is a calm, dense, keyboard-fast app that a normal person can't get wrong. Density never
costs clarity or accessibility.

## What doesn't change

- **Colour.** `Tones` stays the whole colour system: the chosen colour, in solid steps, with no
  gradients and no veils. Dark mode keeps the colour loud. Nothing here adds a colour; it only
  decides which tone goes where.
- **Danger.** Anything that can't be undone is red, sits last, and asks first with a sentence
  that says what happens (`DangerCard`, `confirmationDialog`).
- **Status is words.** A mark sits in front, and the sentence is a hover or a tap away. No
  spinner stands where a sentence belongs.
- **What buttons do.** No button changes what it does to data or the network. A few existing
  actions get a new way in (a shortcut, a swipe, a palette entry, a hover button), and each one
  calls the same model function as before.

## Tokens

All of these live in code, in `Theme.swift` (type and motion) and `Parts.swift` (space, radii,
rows and icons). Screens use the names and never a raw number. In the tables, a pair like
`11 / 13` means the Mac value, then the iPhone value.

### Type

The iPhone's sizes follow Dynamic Type, up to twice the base, as they do now. There are six
steps and no others.

| Token | Size (Mac / iPhone) | Weight | Used for |
| --- | --- | --- | --- |
| `small` | 11 / 13 | regular; medium for a label | Times, second lines, footers, section titles |
| `body` | 13 / 16 | regular; medium for a row's title; semibold when unread or selected | Rows, controls, fields |
| `message` | 14 / 17 | regular | What people write |
| `heading` | 15 / 18 | semibold | Pane and sheet titles, the conversation's name |
| `title` | 20 / 23 | bold | The name at the top of a person, group or You page |
| `display` | 26 / 30 | bold | First run, and your name in You |

- **Section titles** (`SectionTitle`) move from `body` semibold to `small` semibold, in
  secondary ink. The cards carry the page, and the labels get out of the way, as Finder's and
  Linear's do.
- **Secondary ink does most of the work.** Primary ink is for names and what people say. Every
  second line, time, count and footer is `secondary`. `tertiary` is only for marks and for
  disabled controls.
- **Weights.** `heavy` stays only in unread counts.

### Space

Everything sits on a 4 pt grid: **4, 8, 12, 16, 20, 24, 32**. The only exceptions are 2 pt (the
gap between two bubbles in a run, and between a row's two lines) and 1 pt (a hairline).

| Token | Mac | iPhone | Used for |
| --- | --- | --- | --- |
| `Space.side` | 16 | 16 | The page's side margin; 24 in the Mac Settings window |
| `Space.section` | 16 | 24 | Between the sections of a page |
| `Space.title` | 8 | 8 | From a section's title to its card |
| `Space.inset` | 8 + 8 | 8 + 8 | A row's fill is set in 8 pt from its card or column, and its text a further 8 |
| `Space.card` | 4 | 4 | Above the first row in a card and below the last (was 6) |

### Radii

There are four radii on each platform, plus capsules and circles. Nothing else is allowed.

| Token | Mac | iPhone | Used for |
| --- | --- | --- | --- |
| `Radius.small` | 4 | 6 | Keycaps, small chips, a staged file |
| `Radius.row` | 6 | 10 | A row's hover and selection fill, fields, the search field, file blocks |
| `Radius.card` | 10 | 16 | Cards, tiles, photos in messages, popovers, the live-location bar |
| `Radius.bubble` | 16 | 20 | Message bubbles and the composer (a single line reads as a capsule) |
| Capsule | | | Buttons, pills, reactions, counts |
| Circle | | | Faces, icon buttons, the call's controls |

The call screen keeps its own radii (tiles 16, the small call 16/18). It's always dark, and it's
a world of its own.

### Rows

Three heights on each platform. A row is as tall as what it holds, never taller, and it uses
`minHeight`, never a fixed height, so Dynamic Type can grow it (fixes **X6**).

| Row | Mac | iPhone | Holds |
| --- | --- | --- | --- |
| `Rows.line` | 32, glyph slot 20 | 48, glyph slot 28 | One line: Add people, Verify, Leave group, a setting, a palette entry |
| `Rows.person` | 40, face 28 | 60, face 40 | A face and two lines: a member, a friend, a device, someone to pick |
| `Rows.chat` | 40, face 28 | 66, face 44 | The chat list (the iPhone keeps today's size) |

- **Faces**: 20 inline (a mention, the palette), 28 in rows on the Mac, 24 and 32 in a
  conversation header (Mac and iPhone), 64 and 88 at the top of a page.
- **A glyph row has no disc.** `ActionRow`'s icon stops sitting in a filled circle. It's a plain
  glyph in a slot as wide as a person row's face, so the words of every row in a card line up.
  The disc was one more box (**X3**).

### Icons

- They're SF Symbols, weight **medium**, everywhere in the chrome. **semibold** is used only for
  glyphs of 11 pt or less, and on the call's filled discs.
- **Sizes**: 11 / 13 inline (beside small text), 13 / 17 in a row, 15 / 19 in a header or bar.
- **Ink**: secondary at rest, primary on hover or press, red only on a destructive row.

### Hairlines and cards

- **Hairline** (`tones.hairline`, 1 pt): this separates regions that sit next to each other.
  That means the sidebar from the conversation from the details, a header from its content, and
  a pinned footer from what scrolls. It is never drawn around a single thing.
- **Card** (`tones.card`, `Radius.card`, the hue's soft lift): this groups rows on a page made
  of several kinds of things, such as details, You or the person page. There are no hairlines
  inside a card, and no stroke around one.
- **Bare rows** sit right on the ground when the list is the whole page: the chat list, search
  results, the palette, the people picker. Boxing the page's only list is noise (**X3**).
- **Floating** things lift twice as far: the composer, popovers and the call's controls.

### Motion

There are three speeds and one spring. Every animation goes through `Motion`, which turns into
an opacity change, or nothing, under Reduce Motion.

| Token | Value | Used for |
| --- | --- | --- |
| `Motion.press` | 0.08 s ease-out | A press darkening a fill |
| `Motion.quick` | 0.12 s ease-out | A hover fill, a mark changing, hover actions fading in |
| `Motion.standard` | 0.2 s ease-out | Things appearing and going: a pane, the reply strip, a bar |
| `Motion.settle` | spring, response 0.35, damping 0.85 | Things a finger moves that then settle: the swipe reveal, the small call |

- **Scale.** Only buttons and tiles shrink when pressed, to 0.97. Rows and icons never scale.
- **Under Reduce Motion**, nothing slides or scales. Fades stay under 0.15 s. The typing dots,
  the sending ring and the call's ring hold still, as they do today.

## Interaction

### How a press feels

There are four press styles instead of ten. Each is one `ButtonStyle` in `Parts.swift`.

| Style | Rest | Hover (Mac) | Pressed | Used for |
| --- | --- | --- | --- | --- |
| `RowStyle` | clear | `hover` fill | `pressed` fill | Every row you can open |
| `IconStyle` | secondary glyph | primary glyph on a `hover` circle | `pressed` circle | Every icon-only button: the header, ✕, back |
| `Quiet` | `card` capsule (or `loud` when strong) | lifts | `pressed` and 0.97 scale | Every word button |
| `TileStyle` | `card`, lifted | lifts further | settles, 0.97 | Tiles: Message, Call and Video, the empty state |

- **The action fires on release, inside the target.** It never fires on press-down. Drag off a
  target and nothing happens, which is the platform's default; nothing overrides it.
- **Targets.** On the iPhone, every target is at least 44 × 44 pt. On the Mac, every icon is at
  least 24 × 24, and every row at least 28 tall.
- **Dead space between neighbours.** Two targets that lead to different places sit at least
  8 pt apart (12 on the iPhone), with nothing tappable between them. The back button is the case
  this is for (**P3**).
- **Haptics (iPhone).** Sending gives a light impact (as now). Ticking someone in a picker gives
  a selection tick. A destructive answer gives a medium impact. Nothing else buzzes.

### Hover (Mac)

- Every clickable thing shows its hover fill at once. The pointer stays an arrow, as it should
  on the Mac.
- **A row may show its actions on hover**, inline, at its trailing edge, in secondary ink. Under
  the pointer, a message shows its time and way, then React, Reply and More (⋯), which opens the
  same menu as a right click (**M8**).
- **Every icon-only control has a tooltip that names it and its shortcut**, for example "Details
  (⌘I)" or "Mute (⇧⌘A)" (**X8**, **C2**).

### Focus

- **A text field** you're typing in draws a 1.5 pt ring in solid `tones.text`, not the
  system's blue, which clashes with every colour but blue.
- **The sidebar** holds the keyboard after ⌘0 or a click. The arrow keys walk it (as now), and ⏎
  hands the keyboard to the composer of the chat it's on.
- **⎋ closes the topmost thing**: the palette, a sheet, a popover, a thread, the details pane, a
  reply or edit in the composer, and the text in a search field. It closes one thing per press.
- **⏎ is the primary action in every sheet** (`.defaultAction`) and **⎋ is Cancel**
  (`.cancelAction`). Today most sheets do this; all of them will.

### The Mac's keyboard

This is the whole map. Each one is listed in the menu bar, so it shows there with its key, and
in the palette, and in the tooltip of any button that does the same thing.

| Keys | Does | Menu | New? |
| --- | --- | --- | --- |
| ⌘K | Jump to anything, or run a command | Go | |
| ⌘F | Search messages (the sidebar's field) | Go | **new** |
| ⌘1 … ⌘9 | Open the first nine chats in the list | Go ▸ Chats | **new** |
| ⌥⌘↓, ⌥⌘↑ | Next and previous chat | Go | |
| ⌘0 | Put the keyboard in the sidebar | Go | |
| ↑ ↓ ⏎ ⎋ | In the sidebar: move, open (the keyboard goes to the composer), leave | | ⏎ **new** |
| ⌘N | New chat | File | |
| ⇧⌘N | New group | File | |
| ⌥⌘N | New friend (shows your code) | File | **new** |
| ⌘I | Show or hide details | Chat | moved from a hidden button |
| ⇧⌘U | Mark as read | Chat | **new** |
| ⌘⌫ | Delete chat… (asks) | Chat | moved from Go |
| ↑ in an empty composer | Edit your last message | | |
| ⎋ in the composer | Cancel the reply or the edit | | |
| ⏎, ⇧⏎ | Send, new line | | |
| ⌘, | Settings | baud | |
| ⇧⌘1, ⇧⌘2 | Friends and Network, in Settings | Go | |
| ⇧⌘A, ⇧⌘V, ⇧⌘M | In a call: mute, camera, make it small | | shown in tooltips |

When spaces are turned on (`BAUD_SPACES`), ⌘1 and ⌘2 stay Home and Spaces, the chat numbers
aren't used, and New Space moves to ⌃⌥⌘N.

Calls aren't given shortcuts of their own, because a stray chord shouldn't ring anyone. They're
in the palette ("Call Ana", "Video call Ana") and on the Chat menu, without a key.

### Context menus

Everything that represents a thing has a right-click (Mac) or long-press (iPhone) menu, in the
same order everywhere:

1. The main things to do with it (Message, Call, Video call, Reply, React, Open).
2. Copying it, and what's known about it (Copy, Info, Who reacted).
3. Changing it (Edit, Mark as read, Rename).
4. A divider, then anything destructive, last, in red, ending in "…", and asking first.

A menu item shows its shortcut when it has one. The new menus are friends and devices in
Settings and You (**M21**), people in the palette, and the hover More (⋯) on messages.

### Swipes (iPhone)

| Where | Leading swipe | Trailing swipe |
| --- | --- | --- |
| A chat in the list | **Read** (when it's unread), full swipe allowed | Delete / Clear (red, asks; no full swipe), as now |
| A message | Reply, full swipe allowed, as now | Drawn aside to show the time and the way, as now |
| A friend in You | | Remove (red, asks; no full swipe) |

The edge swipe back works on every pushed page, as now.

### One back (iPhone)

Every page that has a way back draws the same one: a 44 pt circle at the leading edge, 8 pt
in from the screen. The chevron is 17 pt medium. It fills with `pressed` while pressed, so you
see what you hit. On a pushed page it's the system's own back (on iOS 26 that is this circle).
Our own headers draw the same circle (**X7**).

## Parts

Every page is built from these. The new parts and the parts that change are listed here. All of
them live in `Parts.swift`.

| Part | What it is | Status |
| --- | --- | --- |
| `SectionTitle` | `small` semibold, secondary | changed (was body) |
| `ListCard` | title, a card of rows, footer | padding changed to 4 |
| `ActionRow` | a glyph in a slot, words, a value; `Rows.line`, `minHeight` | changed (no disc, its own height) |
| `PersonRow` (from `MemberRow`) | face, name, identity mark, one line of how they're reached; `Rows.person` | unified (members, friends, picker, groups-with) |
| `DeviceRow` | glyph, name, status word; `Rows.person` | unified (person page, You, the Mac's Settings) |
| `SheetHeader` | ✕ or Cancel, a title, an optional primary action; 52 pt on the iPhone, 44 on the Mac; a hairline under it | **new**; every sheet's top (**P13**) |
| `PeoplePicker` | search (more than six people), bare `PersonRow`s, a tick each or open on a click | **new**; New chat, New group, Add people (**M18**) |
| `Keycap` | a shortcut in `small` medium on a `Radius.small` chip | **new**; the palette, the empty state, menus drawn by hand |
| `BackButton` | the one back (see above) | **new**; the conversation header |
| `HoverActions` | trailing icon buttons that fade in on hover | **new**; messages |
| `DangerCard` | unchanged | |
| `ActionTile`, `GroupFace`, `ReactionsList`, `MessageInfo`, `ChatMenu` | unchanged, except for tokens | |

`Field`, `Quiet`, `Pill`, `IconButton`, `TileStyle` and `EmptyLine` move into `Parts.swift`, so
that one file holds every part. The two `Pressed` styles and `ActionTile.Pressed` go; `Quiet`
and `TileStyle` cover them.

## Screen by screen

Each change names the audit items it answers.

### Mac sidebar (M1–M5)

```text
●●●                                  [✎]     ← traffic lights, then compose (⌘N, a menu)
┌ 🔍 Search                       ⌘F ┐
└────────────────────────────────────┘
  You            Your devices
  weekend        Jo: who's in for…  ①
  …
──────────────────────────────────────
 (D) Dexter                 ··· Online       ← you (opens Settings) · your status (its sheet)
```

- **The compose button moves into the band by the traffic lights.** Its menu lists New chat ⌘N,
  New group ⇧⌘N and New friend ⌥⌘N, each with its key (**M3**). This frees a whole row.
- **There's no "Chats" title.** The list is the sidebar (**M1**).
- **The search field drops to a quieter fill** (`hover` on `raised`) and shows its ⌘F keycap
  (**M4**, **X8**).
- **The foot is you**: your face and name open Settings, and your status (the mark and its
  word) opens the status sheet. These are two targets, 40 pt or more apart, each with its own
  hover. The face at the top goes (**M2**).
- **A chat row is 40 pt** (from 44), with the same 28 pt face (**M5**).

### Mac conversation (M6–M10)

- **The column.** The timeline, the typing line, the delivery line and the composer sit in a
  column at most 720 pt wide, centred in the pane. The header stays full width. On a 1,080 pt
  window nothing moves; on a full screen the two sides of a chat are about 600 pt apart, not
  1,300 (**M6**).
- **The header.** It's a 24 pt face, then the name in `heading` (15 semibold, from 19 bold) over
  the status in `small`, in a 52 pt band. Call, Video and Details sit at the right, each with its
  shortcut in its tooltip. The face and name open the details, as the name does today (**M7**).
- **Bubbles.** Padding goes from 9 × 14 to 7 × 12, corners to `Radius.bubble` 16 (and 4 inside
  a run), and the gap between runs from 14 to 12. Text stays 14.
- **Hover actions.** These are the time and the way, then React, Reply and More (⋯), beside the
  bubble in the empty side, never on it (**M8**).
- **Reactions.** The add-a-reaction smiley shows only while the pointer is on the message
  (**M9**).
- **The composer's attach button** gets the VoiceOver label "Attach" (**M10**).

### Details: Mac pane and iPhone sheet (M11–M13, P6, P7, X4, X5)

- **A chat with one person shows that person.** It's the person page's own sections, in this
  order:
  - the hero: face, name, how they're reached;
  - Call and Video tiles (no "Message": you're in the chat);
  - Disappearing messages;
  - Safety number;
  - Devices;
  - Groups with them;
  - Remove friend, last, in red.

  The People card that listed you and them goes. This answers "duplicate data" (**M11**).
- **A group** keeps today's order: hero, Disappearing messages, People (Add people first), Leave
  group. Its rows become `PersonRow`s with no device drawings (**M12**). The hero face is 64 pt
  on the Mac (from 72) (**M13**).
- **"admin"** shows only in groups and channels, as a `small` secondary word.
- **The name in the hero is plain text when it can't be renamed.** Today a disabled button dims
  it (**X5**).
- **The header** is a `SheetHeader`: the title on the left and ✕ on the right, ⎋ or ⌘I on the
  Mac. A person or Add people is pushed under the same header on the iPhone, with the one back
  (**P7**).
- **Presence is said once.** The face's light means online. The second line says how they're
  reached ("online", "away 2 h", "through Ana"). The `StatusWord` light in front of the words
  goes (**X4**).

### Person page (P8)

- **Rows take `Rows.line` or `Rows.person`.** "Verify Ana" becomes a 48 pt row, from 66.
- **Device rows are `DeviceRow`s:** glyph, name, and one status phrase ("Direct, 11 ms",
  "Away 2 h"). The path mark is gone and so is the light (**X4**).
- **On the Mac, the popover keeps its 360 pt width** and gets the new spacing.

### When nothing is open (M14)

This becomes a quiet, centred block, lined up on one column:

```text
            No chat open
  New chat                 ⌘N
  New group               ⇧⌘N
  New friend              ⌥⌘N
  Jump to…                 ⌘K
```

These are `RowStyle` rows with keycaps, so a click works and the keys are taught.

### Palette, ⌘K (M15–M17)

- **Sections**, in this order: **This chat** (when one is open), **Chats**, **People**,
  **Actions** and **Messages** (two letters or more), each under a `SectionTitle`.
- **This chat** has Call {name}, Video call {name}, Show details ⌘I, and Mark as read ⇧⌘U when
  it's unread. Each calls the same function its button does.
- **Rows** are `Rows.line`, 32 pt. Groups get their `GroupFace`. The kind word on every row
  goes; the sections say it. Actions show their `Keycap`.
- **"Add" becomes "New friend"** (it shows the QR, as the compose menu's does), and a separate
  **"Friends"** opens Settings at Friends, which is what "Add" did (**X9**).
- **A footer line**: "↑↓ to move · ⏎ to open · ⎋ to close", in `small` secondary.

### New chat and New group (M18)

Both are rebuilt from `SheetHeader` and `PeoplePicker`, the same parts as Add people:

- **New chat** is the picker with no ticks. A click (or ⏎ on the row under the keyboard) opens
  that chat at once. "Open chat" goes.
- **New group** is a Name field (a `Field` in a `ListCard`), then the picker with ticks, and
  "Create" in the header's primary slot. It's disabled until there's a name and a person, and ⏎
  works.
- **Our colours, our rows and our words** ("online", "away 2 h"), and no system list.

### Settings, and You on the iPhone (M19–M21, P10, P11)

The page reads top to bottom as titled cards of rows:

1. **You**: face (64 / 72 pt) with its camera, the name in `display` (tap to rename), and the
   colour.
2. **Colour**, inside your card. The swatches form an even six-column grid on the iPhone (white,
   black, red, orange, amber, green, then teal, blue, violet, pink, any colour) and one row on
   the Mac (**P11**).
3. **Notifications**, only when something is off (as now).
4. **Devices**: "Add a device", then a `DeviceRow` for each device. A click opens the device's
   card (as the tile does now); a right-click or long press offers Remove… (**M20**).
5. **Friends**: "Add a friend", then a `PersonRow` for each friend. A click opens the person; the
   menu has Message, Call, Video call, a divider, then Remove friend… (**M21**).
6. **Network**: the picture, unchanged apart from tokens.
7. **App**: rows for "baud 0.2.21" (with "Up to date · 2:36 PM" and the Check, Update or
   Restart button) and "Open at login" (with its switch).
8. **Start over**, last, in red, asking first.

On the iPhone, You gets a `SheetHeader` that says "You" with a Done button (**P10**).

### iPhone chats (P1, P2)

- **The top row**: your face on the left (it opens You), "Chats" in `heading`, and compose on
  the right. Your status moves under the title as one `small` line: the mark and its word ("···
  Online"). A tap there opens the status sheet. Nothing shares a line with the title any more
  (**P1**).
- **A leading swipe on an unread chat marks it read** (**P2**).

### iPhone conversation (P3–P5)

```text
 (‹)   (A)  Ana                        ☏   ▭   ⓘ
            Online · direct, 4 ms
 └44┘12└────── details ───────┘
```

- **The one back** is a 44 pt circle at the edge. Then come 12 pt of dead space, a 32 pt face,
  and the name over the status, all opening the details. The face gives the details an obvious
  place to aim, and the gap means a thumb that lands between them does nothing (**P3**).
- **The name is `heading`** (18 semibold, from 22 bold). The status gets the room it needs:
  "Online · direct, 4 ms" fits on a 402 pt screen (**P4**).
- **The add-a-reaction smiley after reactions goes.** Double-tap and the long press do this
  (**P5**).

### Location (P12)

- **While the map waits**, it's the ground with "Finding you…" in `small` secondary in the
  middle. The spinner goes.

### Sheets (P13)

- **Every sheet starts with a `SheetHeader`:** Details, You, Add people, New chat, New group,
  the location sheet and the status sheet. The grabber stays where a sheet can be dragged.

### Calls (C1–C4)

- **The Mac's ring panel uses the call screen's words**: Decline, Audio only, Accept (**C1**).
- **The tooltips give the shortcuts**: "Mute (⇧⌘A)", "Turn camera off (⇧⌘V)" and "Make the
  call small (⇧⌘M)" (**C2**).
- **The voice ring rests at 4 pt** (from 6) and swells as before (**C4**).
- **The shade behind the name over video stays.** It's the one gradient, on someone's picture,
  not on our ground (**C3**).

## Words that change

Android mirrors these words (`apps/android`), so each one is listed for the Android pass.

| Where | Was | Becomes | Android |
| --- | --- | --- | --- |
| The Mac's ring panel | Answer / Answer without video | Accept / Audio only | (its own call screen already says Accept) |
| New group sheet | New group chat | New group | check `ui/` for the same sheet |
| Mac palette | Add | New friend, plus Friends | Mac only |
| A direct chat's details | People card with you and them | The person's sections (Call, Video, Safety number, Devices, Groups with) | `ChatInfo.kt`: the same change |
| Member rows in a direct chat | admin | (nothing) | `ChatInfo.kt` |
| You (iPhone) | (no title) | "You" and Done | `You.kt` has its own top bar: compare |
| Chat list | (no leading swipe) | Read | `Chats.kt` |
| Empty Mac pane | New friend / New group tiles | No chat open, then four actions with keys | Mac only |
| New chat | Open chat (button) | (a click on the person opens it) | check |

## The order of the work

Each step is a commit or two, photographed again before the next.

1. Add the tokens and parts to `Theme.swift` and `Parts.swift`, and move the styles there.
   Nothing should look different except the row heights and section titles.
2. Rows and cards: `ActionRow`, `PersonRow`, `DeviceRow`, `ListCard` and `minHeight`
   everywhere.
3. Details, the person page and the people picker (New chat, New group, Add people).
4. The Mac's sidebar, header, column, hover actions, menus and shortcuts.
5. The palette and the empty state.
6. Settings and You.
7. The iPhone's chats, header, back, swipes and sheets.
8. Words and tooltips on calls.
9. The beta script, the QA checklist, and pictures before and after.
