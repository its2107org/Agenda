# Agenda

Ian's to-do and reminders app for iPhone: one place for everything he needs to remember.

- **Brain dump:** tap the microphone and talk through everything on your mind. Speech is turned into text on the phone, then split into separate to-dos, each put in the right list (Work, Social, Home, Errands, Health, Money & admin, Personal) with any dates and times that were said. You check the suggestions and add them in one go. Typing works too; a short line like "Call Sam tomorrow at 3pm" is added straight away.
- **Today:** what slipped (with one tap to move it all to tomorrow), today's to-dos, bookings, standing reminders and calendar events in time order, and what's coming up.
- **Lists:** smart lists (Slipped, Anytime, Important, Done) and Ian's own lists, which he can rename, recolour, reorder and add to.
- **Calendar:** a month view with coloured dots, and everything on the chosen day, including events from the phone's own calendar.
- **Standing reminders:** rent, Mounjaro (every 3½ days, with injection-spot rotation and pen count), anything on a schedule (every few days, weekly or monthly). Optional alarm that rings on silent; repeat nudges until Done. These replace the Nudge app.
- **Bookings:** share a confirmation email, web page, screenshot or PDF to Agenda from the Share menu. It reads the details (date, time, place, confirmation number) and, once checked, adds the booking to Agenda and the phone's calendar.
- **Nudges:** a morning round-up, an evening check of what's still open, a nudge at a to-do's time (and again an hour later), a heads-up before bookings. Notification buttons: Done, In an hour, Tomorrow.
- **Widgets:** Today (tick things off on the Home Screen), Brain dump, Lock Screen widgets, and Control Centre buttons. **Siri:** "Brain dump in Agenda", "Add to Agenda", "What's on today in Agenda".

## How it works

- Sorting uses Claude (Sonnet, structured outputs) with Ian's own key from Settings, kept in the keychain; calls go straight from the phone. Without a key it uses the on-device Apple Intelligence model (guided generation into the same shape), and failing that a simple split with the phone's date finder.
- Data is a JSON file in the app's Application Support folder. The widgets read a small summary from a keychain group shared by the app and its extensions; the Share extension leaves what's shared there for the app to pick up. Widget and alarm buttons are live-activity intents, so they run inside the app. No App Group needed.
- Native SwiftUI, iOS 26.1+, iPhone only. The Xcode project is generated from `project.yml` with XcodeGen. The icon is drawn by `scripts/make_icon.py`.

## Workflows

1. **Set up with Apple**: `check` the secrets, create the `identifiers`, then `certificates`, then `testers`.
2. **Check build and screenshots**: runs on every push; builds for the simulator, runs the self-check (`-AgendaSelfTest`) and saves screenshots to the `screenshots` branch.
3. **Build Agenda**: builds and uploads to TestFlight. Runs on every push to `main`, monthly (so it never expires) and on demand. Uses the same Apple secrets and `Match-Secrets` certificate store as Ian's other apps.
