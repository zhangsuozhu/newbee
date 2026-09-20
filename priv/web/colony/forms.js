import { copyToClipboard } from "./util.js";

// Small accessible dialogs use the existing application controls and theme.

function focusable(element) {
  return !!(element && element !== document.body && document.body.contains(element) &&
    !element.hidden && !element.disabled && element.getClientRects().length && !element.closest('[inert]'));
}
export function restoreFocus(previousFocus) {
  if (!previousFocus || previousFocus === document.body) return;
  setTimeout(() => {
    const menuTrigger = previousFocus.closest?.('.card-menu-wrap')?.querySelector('.card-more');
    const main = document.getElementById('transcript') || document.getElementById('main');
    const target = focusable(previousFocus) ? previousFocus : focusable(menuTrigger) ? menuTrigger : main;
    if (!target) return;
    if ((target.id === 'transcript' || target.id === 'main') && !target.hasAttribute('tabindex')) target.setAttribute('tabindex', '-1');
    target.focus({preventScroll: true});
  }, 50);
}
export function form(title, fields, submitLabel = '保存') {
  return new Promise((resolve) => {
    const previousFocus = document.activeElement;
    const dialog = document.createElement('dialog');
    dialog.className = 'colony-dialog';
    const node = document.createElement('form');
    node.noValidate = true;
    const heading = document.createElement('h3'); heading.textContent = title; node.append(heading);
    const inputs = new Map();
    for (const field of fields) {
      const label = document.createElement('label'); label.textContent = field.label;
      const input = document.createElement(field.options ? 'select' : field.multiline ? 'textarea' : 'input');
      input.name = field.name; input.required = !!field.required;
      if (field.options) for (const option of field.options) { const item = document.createElement('option'); item.value = option.value; item.textContent = option.label; input.append(item); }
      input.value = field.value ?? (field.options?.[0]?.value || '');
      if (field.placeholder) input.placeholder = field.placeholder;
      if (field.type && !field.multiline && !field.options) input.type = field.type;
      if (field.readonly) input.readOnly = true;
      label.append(input); node.append(label); inputs.set(field.name, input);
      if (field.help) { const help = document.createElement('small'); help.textContent = field.help; label.append(help); }

      if (field.copy) {
        // 只读长文本（邀请链接、邀请码）手动选中复制很别扭，给一个明确的复制按钮。
        const copy = document.createElement("button");
        copy.type = "button";
        copy.className = "btn-ghost form-copy";
        copy.textContent = "复制";
        copy.onclick = async () => {
          const ok = await copyToClipboard(input.value);
          if (!ok) { input.focus(); input.select(); }
          copy.textContent = ok ? "已复制" : "复制失败";
          clearTimeout(copy._t);
          copy._t = setTimeout(() => { copy.textContent = "复制"; }, 1500);
        };
        label.append(copy);
      }
    }
    const actions = document.createElement('div'); actions.className = 'honey-actions';
    const cancel = document.createElement('button'); cancel.type = 'button'; cancel.className = 'btn-ghost'; cancel.textContent = '取消'; cancel.onclick = () => dialog.close();
    const submit = document.createElement('button'); submit.type = 'submit'; submit.className = 'btn-allow'; submit.textContent = submitLabel;
    actions.append(cancel, submit); node.append(actions); dialog.append(node); document.body.append(dialog);

    let result = null;
    node.onsubmit = (event) => {
      event.preventDefault();
      for (const field of fields) {
        const input = inputs.get(field.name);
        const value = input.value.trim();
        const error = field.required && !value
          ? '请填写' + field.label + '，不能只输入空格'
          : field.matches !== undefined && value !== field.matches.trim()
            ? '蜂群名称不匹配，请输入完整名称' : (field.validate?.(value) || '');
        input.setCustomValidity(error);
        if (error) {
          input.oninput = () => input.setCustomValidity('');
          input.reportValidity();
          return;
        }
      }
      result = Object.fromEntries([...inputs].map(([key, input]) => [key, input.value.trim()]));
      dialog.close();
    };
    dialog.onclose = () => { dialog.remove(); restoreFocus(previousFocus); resolve(result); };
    dialog.showModal();
  });
}

export function confirmAction(title, message, confirmLabel = '确认') {
  return new Promise((resolve) => {
    const previousFocus = document.activeElement;
    const dialog = document.createElement('dialog');
    dialog.className = 'colony-dialog';
    dialog.setAttribute('role', 'alertdialog');
    dialog.setAttribute('aria-modal', 'true');
    const node = document.createElement('div');
    const heading = document.createElement('h3'); heading.textContent = title;
    const body = document.createElement('p'); body.textContent = message;
    const actions = document.createElement('div'); actions.className = 'honey-actions';
    const cancel = document.createElement('button'); cancel.type = 'button'; cancel.className = 'btn-ghost'; cancel.textContent = '取消';
    const confirm = document.createElement('button'); confirm.type = 'button'; confirm.className = 'btn-deny'; confirm.textContent = confirmLabel;
    cancel.onclick = () => dialog.close('cancel');
    confirm.onclick = () => dialog.close('confirm');
    actions.append(cancel, confirm); node.append(heading, body, actions); dialog.append(node); document.body.append(dialog);
    dialog.onclose = () => { dialog.remove(); restoreFocus(previousFocus); resolve(dialog.returnValue === 'confirm'); };
    dialog.showModal();
    cancel.focus();
  });
}



