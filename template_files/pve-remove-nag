#!/bin/sh
# Proxmox subscription nag removal script
# This script is called after apt upgrades to re-apply patches

# Patch Web UI
WEB_JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
if [ -s "$WEB_JS" ] && ! grep -q "NoMoreNagging" "$WEB_JS"; then
    sed -i.bak -e "/data\.status/ s/!//" -e "/data\.status/ s/active/NoMoreNagging/" "$WEB_JS"
fi

# Patch Mobile UI
MOBILE_TPL=/usr/share/pve-yew-mobile-gui/index.html.tpl
MARKER="<!-- MANAGED BLOCK FOR MOBILE NAG -->"
if [ -f "$MOBILE_TPL" ] && ! grep -q "$MARKER" "$MOBILE_TPL"; then
    cat >> "$MOBILE_TPL" << 'MOBILEEOF'
<!-- MANAGED BLOCK FOR MOBILE NAG -->
<script>
  function removeSubscriptionElements() {
    const dialogs = document.querySelectorAll('dialog.pwt-outer-dialog');
    dialogs.forEach(dialog => {
      const text = (dialog.textContent || '').toLowerCase();
      if (text.includes('subscription')) { dialog.remove(); }
    });
    const cards = document.querySelectorAll('.pwt-card.pwt-p-2.pwt-d-flex.pwt-interactive.pwt-justify-content-center');
    cards.forEach(card => {
      const text = (card.textContent || '').toLowerCase();
      const hasButton = card.querySelector('button');
      if (!hasButton && text.includes('subscription')) { card.remove(); }
    });
  }
  const observer = new MutationObserver(removeSubscriptionElements);
  observer.observe(document.body, { childList: true, subtree: true });
  removeSubscriptionElements();
  setInterval(removeSubscriptionElements, 300);
  setTimeout(() => { observer.disconnect(); }, 10000);
</script>
MOBILEEOF
fi
