# Design pass: QA in 15 minutes

This is a walk through the design pass (see [`system.md`](system.md)) on a local beta, before
anything ships. It covers the iPhone app in a simulator and a Mac copy called "baud Beta". Both
run on demo data, each with a store of its own. Neither touches your real baud, its keys or your
router.

## Start

```sh
build/design-beta.sh          # builds both (about 4 minutes), opens the iPhone simulator and baud Beta
```

- The first launch takes about 20 seconds to fill in the demo people (Ana, Jo, Sam, and Lee, who
  isn't your friend).
- If you close the iPhone app, reopen it with `build/design-beta.sh phone`. Opening it from the
  simulator's home screen starts it as a stranger, on an empty store.
- To reopen the Mac copy, double-click `build/design-beta/baud Beta.app`.
- To see first run on the iPhone, run `build/design-beta.sh first-run`.
- Try both looks: switch the Mac to light or dark, and the simulator with ⇧⌘A. Pick a colour in
  You or Settings; blue and white are the two the pictures were taken in.
- The beta doesn't show notifications. It writes what it would have shown to its log.
- If the beta offers an update, ignore it. That's the real baud's update, and a copy can't take
  it.

## When you're done

```sh
build/design-beta-clean.sh          # quits and unregisters baud Beta, deletes its preferences and folder,
                                    # takes the app off the beta simulator
build/design-beta-clean.sh --sim    # and deletes the "baud beta" simulator too
```

At the end it lists the baud apps this Mac still knows, so you can check that only
`/Applications/baud.app` is left. Xcode's own dev build may also be listed, if you've built
baud in Xcode yourself.

## Round 2 (about 15 minutes)

What changed after the first QA. The round 1 checks follow; where the two disagree, this one
is right. The demo has no archived chats and no muted ones until you make some.

### Mac: Settings and Friends (3 min)

- [ ] ⌘, opens Settings in the main window, not a window of its own: a narrow list (you at the
      top, then Devices, Notifications, Calls, Connection, Updates, Data) beside the section.
      ⎋, ✕ or a click on a chat goes back.
- [ ] You: the colours, then a Hue strip and a Lightness strip. Drag the hue: the whole app
      changes as you drag, nothing is clipped, and the Dock icon changes when you let go.
- [ ] Devices: this Mac, then "Add a device" last. Click it: "Add a device that's yours?" with
      "Add my device" and Cancel. Press Cancel.
- [ ] Updates: "Download and install updates automatically" is on. Turn it off and back on.
- [ ] Data: the store's size, then Start over in red, last; it asks first. Press Cancel.
- [ ] The people button at the top of the sidebar (or ⇧⌘1) opens Friends: Add a friend, a map
      with Ana and Jo (the beta has them sharing where they are), then the friends. Click a face
      on the map: a card with Apple Maps and Google Maps. Click Sam in the list: his page.
- [ ] "··· Online" at the foot opens Connection: this Mac and one word, your other devices, no
      drawing.

### Mac: messages (4 min)

- [ ] Open Sam. Your last message in each run has its time and a mark inside the bubble (✓
      held for him, ✓✓ delivered, filled when read). Rest on the mark: its sentence. There's no
      status line under the conversation, and the header says "Last seen 1 d ago".
- [ ] Hover a message: React, Reply and ⋯ sit in the space beside it. Make the window as narrow
      as it goes, open ⌘I, and hover again: everything stays inside the column and no message is
      cut to "…". Then make it full screen.
- [ ] Hover's React: six recent reactions and +. Give one, then give it again: it's taken back.
      + opens every emoji, with the cursor in its search.
- [ ] Right-click a message: Reply, React ▸, Forward, Copy text, Info, Edit (yours), then Delete
      alone at the end. Each has its icon.
- [ ] Forward a message to Ana: pick her, and it's there, with no "Forwarded".
- [ ] Info on your newest message to Sam: the bubble, Sent, Copy text, then "Held for" Sam and
      which devices hold it. Info on one of Sam's: From "Sam's Mac", How it came.
- [ ] The composer's smiley opens the same emoji picker; a pick goes into the text.
- [ ] Open weekend: no "Reply in thread" anywhere. The beta stages two replies an older baud made
      in a thread ("count me in", "same, if it isn't raining"); they show in the conversation,
      each quoting "who's in for saturday?".

### Mac: chats (3 min)

- [ ] Right-click weekend: Mark as read, Pin chat, Mute notifications ▸, Archive, then Leave and
      delete… last. Each has its icon.
- [ ] Mark Sam as unread: a dot and a bold name. ⇧⌘U toggles it back. Open it: it's read.
- [ ] Pin Jo: it goes to the top. Pin five chats: Pin chat greys out for a sixth.
- [ ] Mute Ana for 1 hour: a bell with a slash after her name, and her count goes quiet.
- [ ] Archive hike: it leaves the list, and an "Archived" row with 1 appears at the foot. Open
      it there, and Unarchive.

### Details and people (2 min)

- [ ] Sam's details (⌘I): his name, then Video, Call, Mute, Search; one card with Disappearing
      messages (and what it does), Nickname, Notifications, Media, links and files, Safety
      number; "No groups in common" with Add to a group; his device; Remove friend last.
- [ ] Click his name: give him a nickname. It shows everywhere, with "Calls themself Sam" under
      it. Remove it the same way.
- [ ] Search: type "files", and a click opens the message where it is.
- [ ] hike's details: the same tiles, Notifications, Media, links and files. Your row says
      "You · Set your label"; set one ("organiser") and it shows after your name. Ana's page
      from hike shows "Label in hike", not editable (you aren't an admin of hike).

### iPhone (3 min)

- [ ] Chats: the people button beside compose opens Friends: Add a friend, a map with Ana and Jo,
      then the friends. Tap a face on the map: a card with Apple Maps and Google Maps.
- [ ] Hold one of Ana's messages: it lifts in place, the rest dims in your colour, six reactions
      above (+ at the end), and Reply, Forward, Copy text, Info below. Tap outside: it closes.
      Hold one of yours near the bottom: the menu flips to fit, with Edit and Delete (red, last).
- [ ] + in the hold menu: every emoji, search at the top with the keyboard up. A tap reacts and
      closes.
- [ ] Double-tap a message: your most recent reaction pops on, and off again with a second
      double tap.
- [ ] Swipe a chat from the left: Read or Unread. From the right: Mute (asks how long) and Delete.
- [ ] Tap your face: You lists the sections; each opens a page. Settings ▸ You: drag the hue and
      the app follows.

## Mac (about 8 minutes)

### First look (30 s)

- [ ] When baud Beta opens for the first time, no chat is open. The pane says "No chat open" with
      four actions and their keys, and a click on one works. Once you've opened a chat, this pane
      doesn't come back, so check it first.

### Sidebar (1 min)

- [ ] There's no "Chats" title. Compose (✎) sits beside the traffic lights, and its menu has New
      chat, New group and New friend.
- [ ] The search field is quieter than before and shows ⌘F. Press ⌘F: the cursor goes into it. ⎋
      clears it, and a second ⎋ hands the keyboard back to the list.
- [ ] At the foot: your face and name open Settings, and "··· Online" on the right opens the
      status sheet. The two are far enough apart that neither is hit for the other.
- [ ] Chat rows are a little tighter (40 pt). Unread counts and delivery marks are where they were.
- [ ] ↑↓ walks the chats. ⏎ puts the cursor in the open chat's composer.

### A conversation (2 min)

- [ ] The header has a face, then the name (smaller and calmer than before) over the status. A
      click on the face or the name opens the details.
- [ ] Make the window full screen. The messages and the composer stay in a column about 720 pt
      wide, so the two sides of the chat aren't a screen apart.
- [ ] Hover over a message. Its time and way show beside it, then React, Reply and ⋯ (More, which
      is the right-click menu). Nothing shows on the bubble itself.
- [ ] The add-a-reaction smiley after a message's reactions shows only while the pointer is on
      the message.
- [ ] Bubbles are a little tighter. Long messages still wrap well, and the delivery line ("Waiting
      for Sam", "Delivered") is under your newest message.

### Details: ⌘I (2 min)

- [ ] Open Sam, then ⌘I. The pane is Sam: the face, "Friend · away 1 d", then Call and Video,
      Disappearing messages, Safety number, Device, and Remove friend last, in red. It doesn't
      list "you and Sam" any more.
- [ ] Remove friend asks first and says what happens. Press Cancel.
- [ ] Open hike and press ⌘I. Its people are rows with a face and how each is reached ("Friend ·
      online", "Through Ana"). There are no tiny device drawings, "admin" sits only by Ana, and
      Add people comes first.
- [ ] "Sam" in Sam's details is in full ink, not greyed out.
- [ ] With the details open and nothing in the composer, ⎋ closes them. ⌘I toggles them too.

### Menus and ⌘K (2 min)

- [ ] File has New Chat ⌘N, New Group ⇧⌘N and New Friend ⌥⌘N.
- [ ] Go has Jump to… ⌘K, Search Messages ⌘F, and Chats ▸ (your first nine chats, ⌘1 to ⌘9).
      Press ⌘2 and ⌘3 to try them.
- [ ] Chat has Call, Video Call, Show Details ⌘I, Mark as Read ⇧⌘U, and Delete Chat… ⌘⌫ last.
      Calls have no keys on purpose.
- [ ] ⌘K shows sections: This chat (Call, Video call, Show details, Mark as read), Chats,
      Actions with their keys, and, once you type, People and Messages. Groups show their faces.
      The footer says ↑↓, ⏎ and esc. Type "ana", then ↓ and ⏎.

### New chat, New group, Settings (1 min)

- [ ] ⌘N: New chat is a list of friends, and one click opens the chat.
- [ ] ⇧⌘N: New group has a name field, the friends with ticks, and Create at the foot. Create
      stays off until there's a name and at least one person. ⏎ creates it, and ⎋ or ✕ closes.
- [ ] ⌘, opens Settings, which is now titled cards of rows top to bottom: you and your colour,
      Devices (Add a device, then this Mac), Friends (Add a friend, then each friend), Network,
      App, then Start over in red.
- [ ] Right-click a friend: Message, Call, Video call, then Remove friend… last.

## iPhone (about 6 minutes)

### Chats (1 min)

- [ ] Top row: your face on the left (You), "Chats" with "··· Online" under it in the middle (tap
      it for the status sheet), compose on the right (New chat, New group, New friend).
- [ ] Swipe an unread chat (weekend, or Ana) from the left: Read. Swipe from the right: Delete,
      which asks first.

### A conversation and the back button (2 min)

- [ ] Open Ana. Back is a round 44 pt button at the edge. Then comes a gap, then Ana's face and
      name. Tap around the gap: nothing happens. Tap the face or the name: the details open. Tap
      back: you're back.
- [ ] The status line ("Online · direct, 4 ms") fits without being cut off.
- [ ] There's no add-a-reaction smiley after reactions. Double-tap a message to give 👍, and long
      press for the rest.
- [ ] The edge swipe back still works.

### Details and a person (2 min)

- [ ] Ana's details are Ana: Call and Video, Disappearing messages, Safety number, Devices (rows
      with "Direct, 11 ms" or "Away 2 h", said once), Groups with Ana, and Remove friend.
- [ ] weekend's details: Add people (a 48 pt row, not a tall one), then the people. Tap Ana:
      her page opens full height. Tap Add people: a page of friends to tick, with Add pinned at
      the bottom.
- [ ] Every sheet starts the same way: its title on the left and ✕ on the right.

### You and the rest (1 min)

- [ ] Tap your face. You has a header ("You" and ✕). The colours are an even grid of six then
      five. Devices and Friends are rows with Add first.
- [ ] Compose ▸ New group: a name field, the friends with ticks, and Create at the bottom.
- [ ] In a chat, + ▸ Location: the sheet has a header, and while the map waits it says "Finding
      you…" instead of showing a spinner.
- [ ] Settings ▸ Accessibility ▸ Display & Text Size ▸ Larger Text, at the largest size: rows grow
      and nothing is cut off.

## Calls

The calls are drawn offscreen for review (`scripts/design-shots.sh calls`). They can't be tried
in the simulator.

- [ ] The Mac's ring panel says Decline, Audio only and Accept, the same words as the call screen.
- [ ] Hovering a call button shows its keys: Mute (⇧⌘A), Turn camera off (⇧⌘V), Make the call
      small (⇧⌘M).
- [ ] The ring around a face on a voice call is lighter at rest and still swells with the voice.

## What to look for everywhere

- **Colour.** Every surface is a solid tone of the chosen colour, with no greys and no washes.
  In dark mode the colour stays loud.
- **One look.** Rows, cards, section titles and sheet headers look the same wherever they are.
- **Danger.** Anything red is last, and asks first in a sentence.
- **Size.** Nothing is tiny or hard to hit. On the iPhone, every target is at least a fingertip
  (44 pt).
