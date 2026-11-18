# Specter: Sonar Sense for iPhone

Kiroween 2026 submission. An iPhone app that turns the speaker and microphone into an inaudible sonar (18-21 kHz) to sense breathing and motion in the air around the phone without a camera or cloud connection[cite: 1, 5].

## Structure
- `core/SpecterCore`: Pure Swift DSP package.
- `app/Specter`: SwiftUI application.
- `lab/`: Python reference implementation and golden vector generators.
- `replay-lab/`: Static website for reviewer replay evaluation.
- `.kiro/`: Steering docs, specs, and custom agent rules.
