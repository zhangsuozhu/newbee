// Small accessible dialogs use the existing application controls and theme.
export function form(title, fields, submitLabel = '保存') {
  return new Promise((resolve) => {
    const dialog = document.createElement('dialog');
    dialog.className = 'colony-dialog';
    const node = document.createElement('form');
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
    }
    const actions = document.createElement('div'); actions.className = 'honey-actions';
    const cancel = document.createElement('button'); cancel.type = 'button'; cancel.className = 'btn-ghost'; cancel.textContent = '取消'; cancel.onclick = () => dialog.close();
    const submit = document.createElement('button'); submit.type = 'submit'; submit.className = 'btn-allow'; submit.textContent = submitLabel;
    actions.append(cancel, submit); node.append(actions); dialog.append(node); document.body.append(dialog);
    let result = null;
    node.onsubmit = (event) => { event.preventDefault(); for (const field of fields) { const input = inputs.get(field.name); if (field.matches !== undefined && input.value.trim() !== field.matches.trim()) { input.setCustomValidity('蜂群名称不匹配，请输入完整名称'); input.reportValidity(); input.oninput = () => input.setCustomValidity(''); return; } } result = Object.fromEntries([...inputs].map(([key, input]) => [key, input.value.trim()])); dialog.close(); };
    dialog.onclose = () => { dialog.remove(); resolve(result); };
    dialog.showModal();
  });
}



