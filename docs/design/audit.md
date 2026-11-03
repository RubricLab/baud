# Design audit

What the Apple apps look like at 0.2.21 (`fd5bdef`), screen by screen, before the design pass.
Every item has an id; [`system.md`](system.md) ties each change to the items it answers.

The pictures were taken on demo data with `scripts/design-shots.sh`. The Mac app walks its own
screens hidden and draws them offscreen. The iPhone app runs in a simulator of its own. The call
screen draws every state offscreen. Each was taken in light and dark, with the colour set to
blue (`0090FF`) and to none. They're kept in `build/design-audit/before/` and aren't checked in.

## Across the app

These come back on almost every screen, so they matter most.

- **X1. There's no one system, only a set of habits.** The code has 13 corner radii (1, 6, 7, 8,
  9, 10, 12, 13, 14, 16, 18, 21 and 22), 15 font sizes set by hand outside `Theme` (8 to 40, used
  about 40 times), 10 animation durations (0.05 to 0.5) and 10 button styles, two of them both
  called `Pressed`. Two screens built from the same parts still don't line up.
- **X2. Single-line rows are as tall as two-line ones.** `ActionRow` ("Add people", "Verify
  Ana", "Leave group", "Send where you are") takes the height of a chat row, which has two lines:
  44 pt on the Mac and 66 pt on the iPhone. The one line floats in the middle with about 20 pt of
  air above and below. This is what makes details and You feel loose.
- **X3. Cards nest inside cards and pages.** A card has a fill, a shadow and 6 pt of padding,
  and it sits on a page that is also a card: the details pane, a sheet. Every list of things gets
  boxed, even where the list is the page. There's no rule for when a hairline is enough.
- **X4. Presence is said twice in one row.** The face carries the online light, and the words
  beside it say "● Online" with a second light. Device rows say "··· ● Direct, 11 ms": the path
  mark, a light, then the words. Settings → Friends, Person → Devices and Chat info → People all
  do this.
- **X5. Hit targets and the words they hold disagree.** When a button is disabled, its label is
  dimmed too. So in Chat info, a person's name can't be renamed, and it shows up greyed out
  ("Sam" in tertiary ink, on both platforms). On the Mac, the add-reaction smiley sits after
  every reaction row, all the time.
- **X6. Fixed heights break Dynamic Type.** `ActionRow`, `MemberRow`, the device rows on the
  person page and the rows in Add people use `.frame(height:)`, not `minHeight`. At the largest
  accessibility sizes, their text is clipped. Chat rows already use `minHeight`, which is right.
- **X7. Back means three different things on the iPhone.** In a conversation, it's our own
  chevron. On a pushed page (a person, Add people), it's the system's glass circle. Inside a
  space, it's "‹ Spaces" in the row style. Each sits in a different place and takes a different
  size of tap.
- **X8. Keyboard shortcuts exist but can't be found.** ⌘K, ⌘N, ⇧⌘N, ⌘I, ⌘0, ⌥⌘↑/↓ and ⌘⌫ all
  work, but only two tooltips mention theirs. The palette doesn't show any. Search can't be
  reached from the keyboard, and there's no ⌘F. ⎋ closes a thread but not the details pane.
- **X9. The same thing has different names.** The call ring says "Accept" and "Audio only", and
  the Mac's ring panel says "Answer" and "Answer without video". The palette's "Add" opens
  Settings at Friends, while everywhere else "New friend" opens the QR. New group is "New group"
  in the compose menu and "New group chat" in its sheet.

## Mac

### Sidebar (`Sidebar.swift`)

- **M1. It's an iPhone header on a Mac.** Your face is on the left, "Chats" sits centred at 16 pt
  bold, and compose is on the right. A Mac sidebar has one list and needs no title. Centring it
  makes the eye jump to the middle of a 264 pt column.
- **M2. You are in two places.** Your face at the top opens Settings. Your status ("··· Online")
  sits at the bottom, alone on a full-width footer under its own hairline. These are the two
  facts about you, and they're 600 pt apart. `YouRow`, which was built to join them, isn't used.
- **M3. The compose menu skips New chat.** It offers New group and New friend. New chat (⌘N) is
  only in the File menu, and none of the three shows its shortcut.
- **M4. The search field is the loudest thing in the sidebar.** It's a full `field` fill. In blue
  it reads as a selected row.
- **M5. The rows are a little loose for a Mac list.** A chat row is 44 pt tall. Two lines (13 pt
  and 11 pt) fit in 40 with the same air.

### Conversation (`ConversationView.swift`, `MacTimeline.swift`, `ComposerView.swift`)

- **M6. On a wide window, the eye has to travel.** The timeline runs the full width of the pane.
  On a full-screen MacBook, their messages sit at the far left and mine at the far right, about
  1,300 pt apart. The composer is just as wide.
- **M7. The header is large and loose.** The name is 19 pt bold in a 58 pt band, larger than any
  other title in the window. There's no face, so the only way to tell people apart at a glance
  is the name.
- **M8. Hover gives you less than the menu.** Hovering over a message shows the time, the way it
  came and React. Reply and the rest of the menu need a right click. Slack and Linear put Reply
  and More on the hover strip.
- **M9. Reactions carry a smiley that's always on.** On the Mac you can hover, so it's noise
  there.
- **M10. The composer's attach button has no label for VoiceOver.** It only has a tooltip.

### Details pane (`MembersView.swift`)

- **M11. A direct chat's details repeat what's already there.** The hero shows "Sam" and
  "Friend · away 1 d". Below it, the People card shows you (marked admin) and Sam ("friend ·
  away 1 d") again. Call, video, the safety number and their devices are one more click away, in
  a popover. "admin" in a chat between two people means nothing.
- **M12. Member rows end in tiny device drawings.** At 14 pt and 40% opacity they don't read.
  They're noise in a row that already says how the person is reached.
- **M13. The group hero is a 72 pt face.** It pushes the people below the fold of a 700 pt
  window.

### When nothing is open (`Overviews.swift`)

- **M14. Two big tiles sit with nothing around them.** "New friend" has an empty second line, and
  "New group" has "⇧⌘N", so their titles don't line up. There's no title and no hint of ⌘K, and
  the rest of the pane is empty.

### Palette, ⌘K (`Palette.swift`)

- **M15. Everything is in one flat list.** Chats, people, commands and messages all run
  together, with "command", "chat" and "group chat" written on the right of every row.
- **M16. A group shows up as a single initial.** The sidebar draws `GroupFace`, so the same
  group looks different in the two places.
- **M17. No command shows its shortcut, and there's no hint for ↑↓ ⏎ ⎋.** Nothing in the open
  chat can be done from the palette either: call, video call, details, mark as read.

### New chat and New group (`NewSheet.swift`)

- **M18. This is the most off-system screen in the app.** It uses the system `List`. In blue,
  that's a block of system grey (`#202020`), with system separators and selection. The faces
  are 18 pt with the light spilling over the initials. The name field has a hairline box around
  it, which nothing else uses. It describes people with words of its own ("online on their
  Mac"). New chat makes you pick one row and then press "Open chat".

### Settings (`SettingsView.swift`)

- **M19. One page uses four ways of showing things.** Your card has no title. Devices are a grid
  of tiles. Friends are rows. Network is a picture. The app card has a layout of its own. Each
  card has its own padding (16 pt inside a card where the rows use 8 pt).
- **M20. Devices are tiles, everywhere else they're rows.** The person page lists devices as
  rows. You can't right-click a device here.
- **M21. You can't right-click a friend in Settings.** In the details pane, the same row has
  Message and Remove on its menu.

### Add (`AddView.swift`)

- **M22. It's in good shape.** The title, the QR, the status and two buttons all work. The only
  problem is that "Scan or paste" is as heavy as "Share" in dark.

### Menus (`MacApp.swift`)

- **M23. The menu bar is thin and arranged by accident.** File has New Chat and New Group, but
  not New Friend. Go mixes navigation (Next, Previous) with actions on a chat (Delete Chat…).
  Details (⌘I) isn't in any menu. There's no Mark as Read.

## iPhone

### Chats (`IOSApp.swift` HomeTab)

- **P1. The top row is busy.** Your face, "··· Online", the centred "Chats" and compose share
  one line. On a 375 pt screen, the status chip runs into the title, and it already shrinks to
  its mark alone.
- **P2. You can swipe a chat to delete it, and that's all.** There's no swipe to mark one as
  read. The long-press menu has it, but nobody looks there.

### Conversation (`ConversationView.swift` Header)

- **P3. Back and details are side by side with nothing between them.** The back chevron's
  target is 46 pt wide. The name block starts about 10 pt to its right, and tapping it opens
  the details. There's no face to aim for, so a thumb aimed at the name and a thumb aimed at
  back land in the same strip. This is the "I always misclick the back button" complaint.
- **P4. The status line cuts off.** "Online · direct, 10…" loses its end on a 402 pt screen.
- **P5. Reactions carry the add-a-reaction smiley on every row.** Double-tap and the long press
  already do this, so it's noise twice over.

### Details sheet

- **P6. It has the same repetition as the Mac (M11), and rows twice the height they need (X2).**
  "Add people" is a single line in a 66 pt row. The name is dimmed (X5).
- **P7. The header is a 52 pt bar with "Group info" and ✕.** Inside it, pushed pages (a person,
  Add people) show the system's floating back circle instead. Two kinds of header live in one
  sheet (X7).

### Person page (`PersonPage.swift`)

- **P8. The page is good, but its rows are loose.** "Verify Ana" is a single line at 66 pt.
  Device rows repeat their status (X4). The system back circle floats over the hero.

### Add people (`PersonPage.swift` AddPeopleSheet)

- **P9. The page works.** It lists friends to tick and pins Add to the bottom. With one friend
  it's a single card in a lot of white, and the disabled "Add" reads as just another grey shape.

### You (`SettingsView.swift` in a sheet)

- **P10. It has no title and no way out but a drag.** Your card starts right under the grabber.
  Every other sheet has a header and ✕.
- **P11. The colour swatches wrap onto two rows.** That looks unplanned. Six then five isn't a
  grid.

### Location (`Location.swift`)

- **P12. While the map waits, a large spinner fills it.** Status is supposed to be words, and the
  row below already says "Finding you…".

### Sheets in general

- **P13. Each sheet decides its own top.** Chat info has a title and ✕. You has a grabber. New
  friend has a centred title and no ✕. Location has a floating ✕ over the map.

## Calls (`CallScreen.swift`, `CallMini.swift`, `CallWindows.swift`)

The calls were overhauled for 0.2.20 and 0.2.21 and hold together well.

- **C1. Ring words differ between the screen and the Mac panel.** See X9.
- **C2. The control buttons have no words, and their tooltips don't give the shortcuts.** The
  shortcuts are ⇧⌘A mute, ⇧⌘V camera and ⇧⌘M small.
- **C3. Over video, the name sits on a black gradient for legibility.** This is the one gradient
  in the app. It stays, because the colour rule is about the app's own ground, not about a shade
  over someone's video. It's noted so it doesn't spread.
- **C4. The voice call's ring is heavy.** At rest it's 6 pt wide around a 128 pt face, and it
  outweighs the name.

## What's already right

These are kept as they are.

- **The colour system.** `Tones` gives every colour solid steps, solved for contrast, and dark
  mode keeps the colour loud.
- **The person page and Add people from 0.2.21.** They're full pages with large targets.
- **Danger cards.** They're red and last, and they ask with a sentence.
- **The edge swipe back.** It works with our own headers.
- **The chat list's density on the iPhone.** It's 66 pt with 44 pt faces, and nobody has
  complained.
- **The call screen.**
