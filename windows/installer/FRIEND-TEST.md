TRANSCRIBER — FRIEND TEST BUILD 0.1.0
====================================

Thank you for testing this early Windows build. It records and transcribes locally: audio and
transcripts are not uploaded by the app.

INSTALLATION AND MODEL DOWNLOAD
-------------------------------
The installer is deliberately small and does not contain AI models. It asks you to choose one
transcription quality and downloads that model plus about 45 MB of speaker-analysis models during
installation. Faster is recommended for the first test. Keep the internet connected until setup
finishes; downloaded files are verified before installation. The app works offline afterward.

GETTING STARTED
---------------
1. Open Transcriber from the Start menu.
2. To transcribe an existing recording, select Import and choose the audio/video file.
3. Select the known number of speakers when possible. Automatic speaker counting is experimental.
4. To record a conversation, select Record. Confirm that the microphone level moves before relying
   on the recording. Stop & transcribe saves and processes the recording.
5. The Stop transcription button cancels an active job. Closing the app during processing also
   cancels and waits for the worker to stop.

IMPORTANT LIMITATIONS
---------------------
* Use this build for evaluation, not as the only recording of a critical meeting.
* Confirm everyone has consented to recording, as required by your organization and local law.
* Speaker labels are estimates. Choose the expected speaker count and check attribution.
* Transcription is CPU-only in this build and can take a while on long recordings.
* Only the model selected during setup is installed. Run setup again to change quality.
* Processing does not resume after cancellation or shutdown.
* The installer is not digitally signed. Windows SmartScreen may show "Unknown publisher"; use
  "More info" and "Run anyway" only if the installer came directly from the project owner.

DATA AND TROUBLESHOOTING
------------------------
Library:  %LOCALAPPDATA%\Transcriber\Library
Logs:     %LOCALAPPDATA%\Transcriber\Logs

Use the Logs button in the app if a transcription fails. When reporting a problem, include the
latest log and describe what you clicked. Logs contain local file paths and processing output, so
review them before sharing.

Uninstall from Windows Settings > Apps > Installed apps > Transcriber. Your local library is kept
so uninstalling the program does not silently delete recordings or transcripts.
