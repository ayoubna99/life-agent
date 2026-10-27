# Life: the Android app

Flutter for the screens and the agent client, Kotlin for what only Android can do.

```
lib/agent/     sign-in (anonymous Supabase user), the API client, the chat loop that runs device tools
lib/device/    the three tools the agent can run on the phone (create_task, set_app_limit, schedule_alarm) and local storage
lib/chat/      the chat screen: text, voice, photos, PDFs, the PDF/pictures the agent makes
lib/ui/        home (today's tasks, start my day, plan tomorrow, review) and settings (sleep time, apps, permissions)
lib/platform/  one interface to everything native, so tests never touch a platform channel
android/app/src/main/kotlin/.../core/   plain Kotlin: usage maths, when to nudge, app-name matching (JVM unit tests)
android/app/src/main/kotlin/.../        Android glue: usage stats, alarms, the limit watcher service, the nudge card, notifications
```

## Build

Needs Flutter 3.41 or newer (Dart 3.11) and the Android SDK. Use the publishable Supabase key (`sb_publishable_...`), never the secret one.

```
cd app
flutter pub get
flutter run --dart-define=SUPA_KEY=sb_publishable_YOUR_KEY
flutter build apk --release --dart-define=SUPA_KEY=sb_publishable_YOUR_KEY
```

The APK is `build/app/outputs/flutter-apk/app-release.apk`. A build without the key shows a message instead of failing on every tap.
`SUPA_URL` can be set the same way if you use another Supabase project (default: the hackathon project).

## First run on a phone

1. Open **Settings** in the app: wake and sleep time, the apps that pull you away, what you work towards. They are saved on the server, so the agent never asks for them.
2. Allow **Usage access** (real screen time), **Notifications**, **Alarms and reminders**, and optionally **Show over other apps** (the nudge card; without it a notification is used).
3. **Plan tomorrow** in the evening. In the morning press **Start my day**: the agent creates the tasks, sets the limits and schedules reminders on this phone.
4. A small notification says Life is watching your limits. When a limited app is open and the limit is near, reached or passed, the agent writes a short message and shows it on top of the app.
5. **Review my day** in the evening compares the plan with what really happened and adapts tomorrow.

## Tests

```
flutter test                      # 69 tests: client, chat loop, device tools, chat, voice, files, home, settings
cd android && ./gradlew testDebugUnitTest   # 29 Kotlin tests: usage maths, nudge rules, app-name matching
```

## What has and has not been run

Run and passing: all the tests above, in a sandbox without a phone. The Kotlin glue was compiled against the real Android 15 framework
classes (with the Flutter embedding classes stubbed), which catches wrong API names and types but not behaviour.

**Not run on a real phone:** reading usage stats, scheduling alarms, the foreground watcher service, the overlay card, the permission screens,
recording audio, the file and photo pickers, text to speech, and the Gradle build itself. Expect to fix small things the first time.
Please report the exact error text.
