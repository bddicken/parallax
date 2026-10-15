import Foundation

/// The script `XLiveStudio` runs in X's Live Studio (x.com/i/live-studio) to
/// start a broadcast the way you would by hand: New Livestream, fill in the
/// title, upload the thumbnail on the Thumbnail tab, back to Details, Go Live.
///
/// Live Studio's markup isn't documented, so buttons and tabs are found by
/// their visible text (or aria-label), and the title box by its label,
/// placeholder or name. It returns nil when it clicked Go Live, or what went
/// wrong, so you can finish by hand.
enum XLiveStudioScript {
    /// Arguments: `title` (may be empty), `thumbnail` (base64 JPEG, or empty
    /// for none).
    static let goLive = """
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const shown = (el) => el && el.getClientRects().length > 0;
    const named = (el) => [el.getAttribute('aria-label'), el.innerText]
      .map((s) => (s ?? '').trim().toLowerCase());
    // The innermost clickable element whose text or label is `name`.
    const control = (root, name) => [...root.querySelectorAll('button, [role=button], [role=tab], a')]
      .filter((el) => shown(el) && named(el).includes(name))
      .pop();
    const enabled = (el) => !el.disabled && el.getAttribute('aria-disabled') !== 'true';
    const waitFor = async (what, find, seconds) => {
      for (const end = Date.now() + seconds * 1000; Date.now() < end; await sleep(250)) {
        const found = find();
        if (found) return found;
      }
      throw `Couldn't find ${what} in Live Studio.`;
    };
    const dialog = () => [...document.querySelectorAll('[role=dialog], [aria-modal=true]')].filter(shown).pop();
    const click = async (what, root, name, seconds = 15) => {
      const el = await waitFor(what, () => {
        const el = control(root(), name);
        return el && enabled(el) ? el : null;
      }, seconds);
      el.click();
      await sleep(500);
    };

    try {
      await click('the New Livestream button', () => document, 'new livestream', 30);
      // Expected to be a popup; if it isn't, look on the whole page.
      const modal = await waitFor('the new livestream window', dialog, 5).catch(() => document);

      if (title) {
        const fields = [...modal.querySelectorAll('input:not([type=file]):not([type=checkbox]):not([type=radio]), textarea, [contenteditable=true]')]
          .filter(shown);
        const labeled = (el) => [el.getAttribute('aria-label'), el.getAttribute('placeholder'), el.getAttribute('name'),
                                 el.labels?.[0]?.innerText]
          .some((s) => (s ?? '').toLowerCase().includes('title'));
        const box = fields.find(labeled) ?? fields[0];
        if (!box) throw "Couldn't find the title box in Live Studio.";
        box.focus();
        if (box.isContentEditable) {
          document.execCommand('selectAll');
          document.execCommand('insertText', false, title);
        } else {
          // Set the value the way typing does, so React sees the change.
          Object.getOwnPropertyDescriptor(Object.getPrototypeOf(box), 'value').set.call(box, title);
          box.dispatchEvent(new Event('input', { bubbles: true }));
          box.dispatchEvent(new Event('change', { bubbles: true }));
        }
      }

      if (thumbnail) {
        await click('the Thumbnail tab', () => dialog() ?? document, 'thumbnail');
        const input = await waitFor('the thumbnail upload', () => (dialog() ?? document).querySelector('input[type=file]'), 10);
        const bytes = Uint8Array.from(atob(thumbnail), (c) => c.charCodeAt(0));
        const files = new DataTransfer();
        files.items.add(new File([bytes], 'thumbnail.jpg', { type: 'image/jpeg' }));
        input.files = files.files;
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        await sleep(2000);
        await click('the Details tab', () => dialog() ?? document, 'details');
      }

      // Go Live stays off until X gets video from your source.
      await click('an enabled Go Live button', () => dialog() ?? document, 'go live', 60);
      return null;
    } catch (problem) {
      return typeof problem === 'string' ? problem : `Live Studio script failed: ${problem}`;
    }
    """
}
