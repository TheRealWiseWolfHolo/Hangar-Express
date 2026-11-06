# Email feedback

Open **Account → Tools → Feedback** or **Settings → Help & Feedback**. Feedback is
available to Standard and Early Access users. The recipient appears in the form;
replies go to the user's sending mailbox.

## What is included

A message is required. The subject is optional. Both optional detail controls
start off each time a new form opens.

| Content | Default | User control |
| --- | --- | --- |
| Message and subject | User enters them | Edit and preview |
| App version/build, generic device model, iOS version | Not included | Include or remove |
| Sanitized sign-in and refresh log | Not included | Include, preview, or remove |
| Screenshots | None | Select, preview, or remove up to three |
| Sender address and display name | Supplied by the email provider | Review in the mail app |

Logs are captured only after opting in, make no extra account request, and use
`DiagnosticPrivacy` redaction and size limits. They may still contain activity or
inventory details. They are not a claim of anonymity.

The system photo picker provides only selected images. Each input is limited to
20 MiB, resized to a 2048-pixel longest edge, and re-encoded as JPEG under 3 MiB.
Original filenames and location metadata are not copied. Visible personal
information remains in the picture. Failed or pending image preparation blocks
continuation rather than silently dropping attachments.

## Sending and replies

Configured Apple Mail opens a composer with the recipient, subject, message, and
selected attachments. The user can edit, cancel, save, or send it. The app does not
claim successful delivery.

Without Apple Mail, an explanation opens before the system share sheet. It offers
message text, `feedback-message.txt`, and all selected attachments. Users must
choose a mail app, enter the displayed recipient, and check the final message.
Other apps decide which shared items they accept.

Share files use a protected, backup-excluded temporary directory and are cleaned
up on dismissal. Saved copies and sent mail follow the chosen provider's policies.
Closing the form discards its in-memory draft. Account or authentication changes
dismiss it. There is no automatic upload or in-app conversation history.

## Build configuration

Supply `SUPPORT_EMAIL_ADDRESS` privately. The public setting stays blank. Release
builds require a valid address; unconfigured Debug builds show a notice and disable
continuation. Public tests use `support@example.invalid`.

See [testing](TESTING.md) for attachment, privacy, and offline UI coverage.
