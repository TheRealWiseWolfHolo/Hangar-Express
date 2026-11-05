# Email feedback

Feedback is available to Standard and Early Access users in Account → Tools and
Settings → Help & Feedback. It prepares email to
the privately configured support address shown in the app. Replies arrive in the user's sending mailbox;
there is no in-app support account, conversation service, or automatic upload.

The form identifies the recipient and explains that email shares the sender's
address/display name through their chosen email provider. A message is required;
subject is optional. Users can preview the prepared body before continuing.

Both optional inclusion controls start off every time the form opens:

- App/device details: the displayed app version/build, generic device model and
  iOS version. No device name, advertising identifier or account snapshot.
- Diagnostic log: a snapshot of the existing in-memory authentication/refresh
  events, sanitized and capped using `DiagnosticPrivacy`. Taking the snapshot
  makes no account/network request. It can still contain activity/inventory
  details, so the complete text is previewable. Disabling the switch removes it.

Users can select up to three images through the system photo picker. Only those
images are loaded; no broad library permission is requested. Inputs are limited
to 20 MiB each, downsampled to a 2048-pixel longest edge and re-encoded as JPEG
under 3 MiB each. Original filenames, location and other original image metadata
are not copied. Pixel content remains visible: users must check the preview and
remove any image they do not want to share. No screenshot is captured automatically.

Configured Apple Mail opens a system composer with the recipient, subject, body
and selected attachments prefilled. The user can review/edit/cancel/send or save
a draft using Mail. The app does not claim successful delivery.

If Apple Mail is unavailable, an explanatory prompt precedes the system share
sheet. It offers the message as text and `feedback-message.txt`, plus all selected
attachments. The user must choose an email app, enter the displayed recipient,
and verify the final message/attachments. Other apps decide what they accept.
Share files use a temporary protected, backup-excluded directory and are removed
on dismissal. User-saved copies and sent mail follow the chosen app/provider's
storage policies. Cancelling returns to the form; closing it discards its local
in-memory contents. Account/authentication changes dismiss it.

Validation covers optional-data exclusion, attachment/preview equality, log
redaction and bounds, image metadata removal/downsampling, invalid image rejection,
fallback file contents and the offline form/preview flow. Tests never send email.

The public source leaves `SUPPORT_EMAIL_ADDRESS` blank. Supply it through ignored
`Config/Local.xcconfig` or private build configuration; Release builds require it.
Public benchmark/UI checks use `support@example.invalid`. Builds without a valid
recipient show an unavailable notice and disable email continuation.
