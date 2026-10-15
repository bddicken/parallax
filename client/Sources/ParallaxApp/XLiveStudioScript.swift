import Foundation

/// The script `XLiveStudio` runs in X's Live Studio (studio.x.com/live) to
/// start a broadcast the way you would by hand: New Livestream, fill in the
/// title, upload the thumbnail on the Thumbnail tab, back to Details, Go Live.
///
/// Live Studio's markup isn't documented, so buttons and tabs are found by
/// their visible text (or aria-label), and the title box by its label,
/// placeholder or name. It returns `{problem, steps, controls}`: `problem`
/// is null when it clicked Go Live, or what went wrong, so you can finish by
/// hand; `steps` is what it did and `controls` what it could see last, for
/// the log.
enum XLiveStudioScript {
    /// Arguments: `title` (may be empty), `thumbnail` (base64 JPEG, or empty
    /// for none), `dryRun` (stop short of clicking Go Live).
    static let goLive = """
    const steps = [];
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
      steps.push(`clicked ${what}: ${el.tagName.toLowerCase()} "${named(el).filter(Boolean)[0]}"`);
      await sleep(500);
    };
    // The buttons, tabs and fields in view, to see what changed on X's side.
    const controls = () => [...(dialog() ?? document).querySelectorAll('button, [role=button], [role=tab], input, textarea, [contenteditable=true]')]
      .filter((el) => shown(el) || el.type === 'file')
      .map((el) => [el.tagName.toLowerCase(), el.getAttribute('role'), el.type, named(el).filter(Boolean)[0],
                    el.getAttribute('placeholder'), el.disabled || el.getAttribute('aria-disabled') === 'true' ? 'disabled' : null]
        .filter(Boolean).join(' '))
      .slice(0, 80)
      .concat(
        // Anything else that looks like the controls we want, however it's built.
        [...document.querySelectorAll('body *')]
          .filter((el) => shown(el) && /live|stream|new|create|thumbnail|title|details/i.test(el.innerText ?? '')
                  && (el.innerText ?? '').trim().length < 40 && ![...el.children].some((c) => c.innerText === el.innerText))
          .map((el) => `text ${el.tagName.toLowerCase()} role=${el.getAttribute('role')} testid=${el.getAttribute('data-testid')} `
               + `cursor=${getComputedStyle(el).cursor} "${el.innerText.trim()}"`)
          .slice(0, 60),
        [...document.querySelectorAll('iframe')].map((f) => `iframe ${f.src} ${f.getClientRects().length ? 'shown' : 'hidden'}`),
        [`page ${document.readyState} ${location.href} main=${document.querySelector('main')?.innerText?.length ?? 'none'}`],
        [`page: ${(document.body.innerText ?? '').replace(/\\s+/g, ' ').slice(0, 1500)}`]);

    try {
      await click('the New Livestream button', () => document, 'new livestream', 30);
      // Expected to be a popup; if it isn't, look on the whole page.
      const modal = await waitFor('the new livestream window', dialog, 5).catch(() => document);
      steps.push(modal === document ? 'no popup; using the page' : 'popup open');

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
        steps.push(`title box ${box.tagName.toLowerCase()} now "${box.value ?? box.innerText}"`);
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
        steps.push(`attached thumbnail (${bytes.length} bytes)`);
        await sleep(2000);
        const images = [...(dialog() ?? document).querySelectorAll('img')].filter(shown).map((i) => i.src.slice(0, 30));
        steps.push(`images in the popup: ${images.join(', ') || 'none'}`);
        await click('the Details tab', () => dialog() ?? document, 'details');
      }

      if (dryRun) {
        const go = await waitFor('the Go Live button', () => control(dialog() ?? document, 'go live'), 15);
        const titleBox = (dialog() ?? document).querySelector('input[placeholder="Enter a title..."]');
        steps.push(`dry run: title box says "${titleBox?.value}"`);
        steps.push(`dry run: found Go Live (${enabled(go) ? 'enabled' : 'disabled'}), not clicking`);
        return { problem: null, steps, controls: controls() };
      }
      // Go Live stays off until X gets video from your source.
      await click('an enabled Go Live button', () => dialog() ?? document, 'go live', 60);
      return { problem: null, steps, controls: [] };
    } catch (problem) {
      return { problem: typeof problem === 'string' ? problem : `Live Studio script failed: ${problem}`,
               steps, controls: controls() };
    }
    """
}
