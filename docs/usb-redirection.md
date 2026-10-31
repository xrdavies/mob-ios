# USB redirection: iOS scope

Status: draft USB-1, 2026-11-01. Not implemented or released.

The [mobd USB design](https://github.com/xrdavies/mobd/blob/main/docs/usb-redirection.md)
is the canonical contract. Mob Desktop exports a selected local USB device and
mobd imports it, using USB/IP over an authenticated, encrypted reverse tunnel
and open-source implementations only. The first receiver is Linux; Windows and
macOS receivers are later, independently verified milestones.

## Role in the first delivery

iOS does not export devices attached to an iPhone/iPad, import virtual USB devices,
or carry Desktop's USB traffic. No USB driver, accessory framework, entitlement
or new background service is required in this app for that scope. Phone USB
support would require a separate feasibility study, not an inference from macOS.

The app can continue chatting with an agent on a remote machine where Desktop
has shared hardware. Whether an agent/tool can access it depends on the remote
OS permissions and driver. This does not transfer ownership of the USB session
to iOS or isolate the device to the current chat.

Do not add a Share USB button or automatic session release to mobile chat/live
view code. Switching chats/machines, backgrounding or disconnecting this phone
must not interrupt another client's active USB share. Session operations belong
to the originating Desktop client; remote local administrator recovery remains
available as described by mobd.

## Compatibility and optional later status

The proposed `usbRedirection` health feature means server contract support, not
that the phone can share USB or every device is usable. Missing/unknown features
must leave chat, files and live view usable. No USB API call or model expansion
is necessary for the first Desktop-only delivery.

A later status UI must use the shared server authorization policy and states
`connecting`, `connected`, `disconnecting`, `disconnected`, `failed`. It must
not expose another client's device inventory or controls without a separately
specified API permission. Do not build mobile management as part of this draft.

System document-picker access to an external drive remains ordinary
[file transfer](file-transfers.md), subject to iOS/provider permissions. It does
not expose a USB device or grant remote block-level access. USB writes/flashing
cannot use file-transfer pause/continue semantics.

## Apple application and validation

[mobd's Apple runbook](https://github.com/xrdavies/mobd/blob/main/docs/apple-usb-entitlement.md)
records the required `com.apple.developer.usb.host-controller-interface`
application for a receiving Mac, entry points and materials. It does not apply
to the iOS target, and an existing Apple signing certificate does not grant it.
No application is submitted by this documentation change.

When the Desktop feature lands, verify iOS still works with old/new mobd and
that its view/background lifecycle cannot terminate Desktop's hardware session.
If status is later implemented, add only the relevant parsing/authorization tests
in `Data/` and lifecycle coverage in `State/` and the affected UI. No runtime or
signing change is needed merely to document this boundary.
