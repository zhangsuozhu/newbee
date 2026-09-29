/* Provider → credential group → model editor. */
window.ModelCatalog = (() => {
  const esc = (s) =>
    String(s ?? "").replace(
      /[&<>"']/g,
      (c) =>
        ({
          "&": "&amp;",
          "<": "&lt;",
          ">": "&gt;",
          '"': "&quot;",
          "'": "&#39;",
        })[c],
    );
  const protocols = [
    ["openai-completions", "Chat Completions"],
    ["openai-responses", "Responses"],
    ["anthropic", "Anthropic Messages"],
    ["auto", "自动探测"],
    ["typesafe-systemone", "TypeSafe / Jev SystemOne"],
  ];
  const opts = (v, inherit = false) =>
    (inherit ? '<option value="">继承厂家</option>' : "") +
    protocols
      .map(
        ([id, n]) =>
          `<option value="${id}" ${id === ({ chat: "openai-completions", responses: "openai-responses", "anthropic-messages": "anthropic" }[v] || v) ? "selected" : ""}>${n}</option>`,
      )
      .join("");
  let rpc, data, cfg, pid, gid, dirty, busy, root, focus;
  const $ = (id) => root.querySelector("#" + id),
    p = () => cfg.providers[pid],
    g = () => p()?.groups[gid];
  const bind = (id, fn, event = "click") => $(id)?.addEventListener(event, fn);
  function status(s, error = false) {
    $("catalog-status").textContent = s;
    $("catalog-status").classList.toggle("error", error);
  }
  function mark() {
    dirty = true;
    status("有未保存的修改");
  }
  function field(id, obj, key) {
    bind(
      id,
      (e) => {
        obj[key] = e.target.value;
        mark();
      },
      "input",
    );
  }
  function close() {
    if (busy || (dirty && !confirm("有未保存的修改，确定放弃？"))) return;
    root.classList.add("hidden");
    focus?.focus();
  }
  function valid(id, map) {
    if (
      !id ||
      /[\s/~]/u.test(id) ||
      ["__proto__", "constructor", "prototype"].includes(id)
    ) {
      status("ID 不能为空，不能包含空白、/ 或 ~", true);
      return false;
    }
    if (Object.hasOwn(map, id)) {
      status("这个 ID 已存在", true);
      return false;
    }
    return true;
  }
  function isJev(model, provider = p()) {
    return (
      model.kind === "jev" ||
      (model.api || provider?.api) === "typesafe-systemone"
    );
  }
  function unbind(test) {
    if (cfg.compaction?.jev?.modelRef && test(cfg.compaction.jev.modelRef)) {
      delete cfg.compaction.jev.modelRef;
      cfg.compaction.mode = "legacy";
    }
    for (const [r, v] of Object.entries(cfg.roles))
      if (test(v)) delete cfg.roles[r];
  }
  async function open(call) {
    rpc = call;
    data = await rpc("llm.catalogConfig", {});
    cfg = data.config;
    cfg.roles ||= {};
    pid = cfg.roles.default?.provider || Object.keys(cfg.providers)[0];
    gid = cfg.roles.default?.group || Object.keys(p()?.groups || {})[0];
    dirty = false;
    busy = false;
    focus = document.activeElement;
    root = document.getElementById("mcfg-modal");
    root.innerHTML = `<section class="catalog-box" role="dialog" aria-modal="true" aria-labelledby="catalog-title"><header><div><h2 id="catalog-title">模型配置</h2><p>厂家管理接入地址 · 分组管理 API Key · 模型管理接口与能力</p></div><button id="catalog-close" aria-label="关闭模型配置">✕</button></header><div class="catalog-layout"><nav aria-label="厂家列表"><h3>厂家</h3><div id="catalog-providers"></div><div class="catalog-create"><input id="catalog-provider-id" aria-label="新厂家 ID" placeholder="新厂家 ID，如 newapi"><button id="catalog-add-provider">＋ 厂家</button></div></nav><main id="catalog-editor"></main></div><details class="catalog-roles"><summary>用途绑定（聊天角色 / Jev 压缩）</summary><div id="catalog-roles"></div><section id="catalog-jev" class="catalog-jev"></section></details><footer><div><span id="catalog-status" role="status"></span><small id="catalog-path"></small></div><button id="catalog-cancel">取消</button><button id="catalog-save" class="primary">保存全部配置</button></footer></section>`;
    $("catalog-path").textContent = data.path;
    bind("catalog-close", close);
    bind("catalog-cancel", close);
    bind("catalog-save", save);
    bind("catalog-add-provider", () => {
      const id = $("catalog-provider-id").value.trim();
      if (!valid(id, cfg.providers)) return;
      cfg.providers[id] = {
        name: id,
        baseUrl: "",
        api: "openai-completions",
        groups: {},
      };
      pid = id;
      gid = null;
      $("catalog-provider-id").value = "";
      mark();
      render();
      $("catalog-url").focus();
    });
    root.onmousedown = (e) => {
      if (e.target === root) close();
    };
    root.onkeydown = (e) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        close();
      }
      if (e.key === "Tab") {
        const a = [
          ...root.querySelectorAll("button,input,select,summary"),
        ].filter((x) => !x.disabled && x.getClientRects().length);
        if (e.shiftKey && document.activeElement === a[0]) {
          e.preventDefault();
          a.at(-1)?.focus();
        }
        if (!e.shiftKey && document.activeElement === a.at(-1)) {
          e.preventDefault();
          a[0]?.focus();
        }
      }
    };
    render();
    root.classList.remove("hidden");
    $("catalog-close").focus();
    status("旧配置首次保存时自动备份；密钥留空表示保持原值");
  }
  function render() {
    providers();
    editor();
    roles();
  }
  function providers() {
    $("catalog-providers").innerHTML =
      Object.entries(cfg.providers)
        .map(
          ([id, v]) =>
            `<button class="catalog-provider ${id === pid ? "selected" : ""}" data-provider="${esc(id)}"><strong>${esc(v.name || id)}</strong><small>${esc(id)} · ${Object.keys(v.groups).length} 个分组</small></button>`,
        )
        .join("") || '<p class="muted">添加第一个接入厂家</p>';
    $("catalog-providers")
      .querySelectorAll("[data-provider]")
      .forEach(
        (b) =>
          (b.onclick = () => {
            pid = b.dataset.provider;
            gid = Object.keys(p().groups)[0];
            render();
          }),
      );
  }
  function editor() {
    const v = p();
    if (!v) {
      $("catalog-editor").innerHTML =
        '<div class="catalog-empty">先添加厂家，再添加凭证分组和模型。</div>';
      return;
    }
    if (!v.groups[gid]) gid = Object.keys(v.groups)[0];
    $("catalog-editor").innerHTML =
      `<section class="catalog-section"><div class="catalog-heading"><h3>1 · 厂家 <small>${esc(pid)}</small></h3><button id="catalog-delete-provider" class="danger">删除厂家</button></div><div class="catalog-fields"><label>厂家显示名称<input id="catalog-provider-name" value="${esc(v.name || pid)}"></label><label>默认接口<select id="catalog-api">${opts(v.api || "openai-completions")}</select></label></div><label>API 根地址<input id="catalog-url" placeholder="https://api.example.com/v1" value="${esc(v.baseUrl)}"></label><p class="muted">填写官方厂家、New API 或 Sub2API 服务的 API 根地址。</p></section><section class="catalog-section"><h3>2 · 凭证分组</h3><div class="catalog-group-tabs" id="catalog-groups"></div><div class="catalog-create"><input id="catalog-group-id" aria-label="新分组 ID" placeholder="新分组 ID，如 premium"><button id="catalog-add-group">＋ 分组</button></div><div id="catalog-group-editor"></div></section>`;
    field("catalog-provider-name", v, "name");
    field("catalog-url", v, "baseUrl");
    bind(
      "catalog-provider-name",
      () => {
        providers();
        roles();
      },
      "change",
    );
    bind(
      "catalog-api",
      (e) => {
        v.api = e.target.value;
        mark();
      },
      "change",
    );
    bind("catalog-delete-provider", () => {
      if (!confirm("删除厂家及其分组、模型和角色绑定？")) return;
      unbind((r) => r.provider === pid);
      delete cfg.providers[pid];
      pid = Object.keys(cfg.providers)[0];
      gid = null;
      mark();
      render();
    });
    $("catalog-groups").innerHTML = Object.entries(v.groups)
      .map(
        ([id, w]) =>
          `<button data-group="${esc(id)}" class="${id === gid ? "selected" : ""}">${esc(w.name || id)} <small>${w.models.length} 模型</small></button>`,
      )
      .join("");
    $("catalog-groups")
      .querySelectorAll("[data-group]")
      .forEach(
        (b) =>
          (b.onclick = () => {
            gid = b.dataset.group;
            editor();
          }),
      );
    bind("catalog-add-group", () => {
      const id = $("catalog-group-id").value.trim();
      if (!valid(id, v.groups)) return;
      v.groups[id] = { name: id, apiKey: "", models: [] };
      gid = id;
      mark();
      render();
      $("catalog-key").focus();
    });
    groupEditor();
  }
  function groupEditor() {
    const w = g();
    if (!w) {
      $("catalog-group-editor").innerHTML =
        '<p class="muted">每个分组独立配置一个 API Key 和可用模型。</p>';
      return;
    }
    $("catalog-group-editor").innerHTML =
      `<div class="catalog-heading"><h4>分组 · ${esc(gid)}</h4><button id="catalog-delete-group" class="danger">删除分组</button></div><div class="catalog-fields"><label>分组显示名称<input id="catalog-group-name" value="${esc(w.name || gid)}"></label><label><span class="catalog-field-title">API Key <span id="catalog-key-hint" class="muted">${w.keyConfigured ? "已配置 · 留空保持" : "未配置"}</span></span><input id="catalog-key" aria-describedby="catalog-key-hint" type="password" autocomplete="new-password" placeholder="API Key 或 &#36;{ENV_VAR}" value="${esc(w.apiKey || "")}"></label></div><div class="catalog-heading"><h3>3 · 模型 <small>${w.models.length} 个</small></h3><div><button id="catalog-fetch">从此分组导入模型</button> <button id="catalog-add-model">＋ 模型</button> <button id="catalog-add-jev">＋ Jev 评分模型</button></div></div><p class="muted">名称用于选用，ID 原样发送。窗口按 K / M token 填写（1 K = 1,000，1 M = 1,000,000），留空自动。导入只追加，不覆盖已有属性。</p><label>筛选模型<input id="catalog-model-filter" type="search" placeholder="搜索显示名称或请求 ID"></label><div id="catalog-models"></div>`;
    field("catalog-group-name", w, "name");
    bind(
      "catalog-group-name",
      () => {
        editor();
        roles();
      },
      "change",
    );
    bind(
      "catalog-key",
      (e) => {
        w.apiKey = e.target.value || (w.keyConfigured ? null : "");
        mark();
      },
      "input",
    );
    bind("catalog-delete-group", () => {
      if (!confirm("删除分组及其模型和角色绑定？")) return;
      unbind((r) => r.provider === pid && (r.group || "default") === gid);
      delete p().groups[gid];
      gid = null;
      mark();
      render();
    });
    bind("catalog-add-jev", () => {
      w.models.push({
        id: w.models.some((m) => m.id === "jev-latest") ? "" : "jev-latest",
        name: "Jev 评分",
        kind: "jev",
        api: "typesafe-systemone",
      });
      mark();
      models();
      roles();
      $("catalog-models")
        .lastElementChild.querySelector("[data-field=id]")
        .focus();
    });
    bind("catalog-add-model", () => {
      w.models.push({ id: "", name: "" });
      mark();
      models();
      $("catalog-models")
        .lastElementChild.querySelector('[data-field="id"]')
        .focus();
    });
    bind("catalog-model-filter", filterModels, "input");
    bind("catalog-fetch", fetchModels);
    if (w.models.length && w.models.every((m) => isJev(m))) {
      $("catalog-fetch").disabled = true;
      $("catalog-fetch").title = "Jev 使用专用评分接口，请直接添加模型 ID";
    }
    models();
  }
  function isDefault(m) {
    const d = cfg.roles.default;
    return (
      d?.provider === pid && (d.group || "default") === gid && d.model === m.id
    );
  }
  function filterModels() {
    const query = $("catalog-model-filter").value.toLowerCase();
    $("catalog-models")
      .querySelectorAll("article")
      .forEach((row) => {
        const model = g().models[Number(row.dataset.index)];
        row.hidden = !(String(model.id || "") + " " + (model.name || ""))
          .toLowerCase()
          .includes(query);
      });
  }
  function contextScale(tokens) {
    return tokens >= 1000000 ? 1000000 : 1000;
  }
  function models() {
    $("catalog-model-filter").value = "";
    const w = g();
    $("catalog-group-editor").querySelector("h3 small").textContent =
      `${w.models.length} 个`;
    $("catalog-groups")
      .querySelectorAll("[data-group]")
      .forEach((tab) => {
        if (tab.dataset.group === gid)
          tab.querySelector("small").textContent = `${w.models.length} 模型`;
      });
    $("catalog-models").innerHTML =
      w.models
        .map(
          (m, i) =>
            `<article class="catalog-model" data-index="${i}"><div class="catalog-model-kind"><label>模型类型<select data-kind aria-label="模型 ${i + 1} 类型"><option value="chat" ${!isJev(m) ? "selected" : ""}>普通对话模型</option><option value="jev" ${isJev(m) ? "selected" : ""}>Jev 评分 / 决策模型</option></select></label></div><div class="catalog-fields"><label>请求 ID<input data-field="id" aria-label="模型 ${i + 1} 请求 ID" value="${esc(m.id)}" placeholder="如 openai/gpt-4.1"></label><label>显示名称<input data-field="name" aria-label="模型 ${i + 1} 显示名称" value="${esc(m.name)}" placeholder="留空使用 ID"></label><label>接口类型<select data-field="api">${opts(m.api, true)}</select></label><label>上下文窗口（token）<span class="catalog-context-input"><input data-field="contextWindow" aria-label="模型 ${i + 1} 上下文窗口数值" type="number" min="0" step="any" value="${m.contextWindow == null ? "" : esc(m.contextWindow / contextScale(m.contextWindow))}" placeholder="自动"><select data-context-unit aria-label="模型 ${i + 1} 上下文窗口单位"><option value="1000" ${contextScale(m.contextWindow) === 1000 ? "selected" : ""}>K</option><option value="1000000" ${contextScale(m.contextWindow) === 1000000 ? "selected" : ""}>M</option></select></span></label></div><details><summary>模型能力与高级选项</summary><div class="catalog-fields"><label>图片输入<select data-cap="vision"><option value="">继承 / 自动</option><option value="true" ${[true, "true"].includes(m.capabilities?.vision) ? "selected" : ""}>支持</option><option value="false" ${[false, "false"].includes(m.capabilities?.vision) ? "selected" : ""}>不支持</option></select></label><label>Responses 续接<select data-field="responsesContinuation"><option value="">继承厂家</option><option value="true" ${[true, "true"].includes(m.responsesContinuation) ? "selected" : ""}>启用</option><option value="false" ${[false, "false"].includes(m.responsesContinuation) ? "selected" : ""}>禁用</option></select></label>${["imageMaxBytes", "maxImagesPerRequest", "maxRequestImageBytes"].map((k, j) => `<label>${["单张图片字节上限", "单次图片数量上限", "单次图片总字节上限"][j]}<input type="number" min="1" data-cap="${k}" value="${esc(m.capabilities?.[k])}"></label>`).join("")}<label>System 提示更新<select data-cap="systemPromptUpdate"><option value="">继承 / 未声明</option><option value="in-history" ${m.capabilities?.systemPromptUpdate === "in-history" ? "selected" : ""}>支持历史中更新</option></select></label></div></details><div class="catalog-model-actions"><button data-default="${i}">${isDefault(m) ? "✓ 默认模型" : "设为默认"}</button><button data-remove="${i}" class="danger">移除</button></div></article>`,
        )
        .join("") ||
      '<div class="catalog-empty">此分组尚无模型，手动添加或从接口导入。</div>';
    $("catalog-models")
      .querySelectorAll("article")
      .forEach((row) => {
        const m = w.models[Number(row.dataset.index)];
        if (isJev(m)) {
          row
            .querySelector("[data-field=contextWindow]")
            .closest("label")
            .remove();
          row.querySelector("details").remove();
          const api = row.querySelector("[data-field=api]");
          api.innerHTML =
            '<option value="typesafe-systemone">TypeSafe / Jev SystemOne</option>';
          api.disabled = true;
          row.querySelector("[data-default]").textContent = "用于上下文压缩";
          row
            .querySelector(".catalog-model-actions")
            .insertAdjacentHTML(
              "beforebegin",
              '<p class="muted">使用 state / questions 评分接口，不参与聊天。调用预算在下方「用途绑定」中设置。</p>',
            );
        } else {
          row
            .querySelector(
              '[data-field=api] option[value="typesafe-systemone"]',
            )
            ?.remove();
        }
        row.querySelector("[data-kind]").onchange = (e) => {
          unbind(
            (r) =>
              r.provider === pid &&
              (r.group || "default") === gid &&
              r.model === m.id,
          );
          m.kind = e.target.value;
          m.api =
            m.kind === "jev" ? "typesafe-systemone" : "openai-completions";
          mark();
          models();
          roles();
        };

        row.querySelectorAll("[data-field]").forEach((el) =>
          el.addEventListener(
            el.tagName === "SELECT" ? "change" : "input",
            () => {
              const k = el.dataset.field,
                old = m[k];
              if (el.value === "") delete m[k];
              else
                m[k] =
                  k === "contextWindow"
                    ? Math.round(
                        Number(el.value) *
                          Number(
                            row.querySelector("[data-context-unit]").value,
                          ),
                      )
                    : k === "responsesContinuation"
                      ? el.value === "true"
                      : el.value;
              if (k === "id")
                for (const r of [
                  ...Object.values(cfg.roles),
                  cfg.compaction?.jev?.modelRef,
                ].filter(Boolean))
                  if (
                    r.provider === pid &&
                    (r.group || "default") === gid &&
                    r.model === old
                  )
                    r.model = m.id;
              mark();
              roles();
            },
          ),
        );
        row
          .querySelector("[data-context-unit]")
          ?.addEventListener("change", () => {
            row
              .querySelector('[data-field="contextWindow"]')
              .dispatchEvent(new Event("input"));
          });
        row.querySelectorAll("[data-cap]").forEach((el) =>
          el.addEventListener("change", () => {
            m.capabilities ||= {};
            const k = el.dataset.cap;
            if (el.value === "") delete m.capabilities[k];
            else
              m.capabilities[k] =
                k === "vision"
                  ? el.value === "true"
                  : k === "systemPromptUpdate"
                    ? el.value
                    : Number(el.value);
            mark();
          }),
        );
        row.querySelector("[data-default]").onclick = () => {
          if (!m.id) {
            status("请先填写模型 ID", true);
            return;
          }
          if (isJev(m)) {
            cfg.compaction ||= {};
            cfg.compaction.jev ||= {};
            cfg.compaction.mode = "jev";
            cfg.compaction.jev.modelRef = {
              provider: pid,
              group: gid,
              model: m.id,
            };
            mark();
            roles();
            $("catalog-jev").closest("details").open = true;
            $("catalog-jev").scrollIntoView({ block: "nearest" });
            return;
          }
          cfg.roles.default = {
            ...cfg.roles.default,
            provider: pid,
            group: gid,
            model: m.id,
          };
          mark();
          models();
          roles();
        };
        row.querySelector("[data-remove]").onclick = () => {
          unbind(
            (r) =>
              r.provider === pid &&
              (r.group || "default") === gid &&
              r.model === m.id,
          );
          w.models.splice(Number(row.dataset.index), 1);
          mark();
          models();
          roles();
        };
      });
  }
  function renderJevUsage() {
    const choices = [];
    for (const [provider, v] of Object.entries(cfg.providers))
      for (const [group, w] of Object.entries(v.groups))
        for (const m of w.models)
          if (m.id && isJev(m, v))
            choices.push({
              provider,
              group,
              model: m.id,
              label: `${v.name || provider} / ${w.name || group} / ${m.name || m.id}`,
            });
    const compact = cfg.compaction || {},
      raw = compact.jev || {},
      ref = raw.modelRef;
    const same = (c) =>
      ref &&
      c.provider === ref.provider &&
      c.group === ref.group &&
      c.model === ref.model;
    const mode = compact.mode || "";
    const budget = (key, label, fallback) => {
      const n = raw[key] ?? fallback,
        scale = contextScale(n);
      return `<label>${label}<span class="catalog-context-input"><input data-jev-budget="${key}" aria-label="${label}数值" type="number" min="0" step="any" value="${esc(n / scale)}"><select data-jev-unit="${key}" aria-label="${label}单位"><option value="1000" ${scale === 1000 ? "selected" : ""}>K</option><option value="1000000" ${scale === 1000000 ? "selected" : ""}>M</option></select></span></label>`;
    };
    $("catalog-jev").innerHTML = `<h3>上下文压缩 · Jev 评分</h3>
      <div class="catalog-fields"><label>压缩方式<select id="catalog-compact-mode"><option value="" ${mode === "" ? "selected" : ""}>沿用原配置（自动）</option><option value="legacy" ${mode === "legacy" ? "selected" : ""}>常规压缩，不使用 Jev</option><option value="jev" ${mode === "jev" ? "selected" : ""}>Jev 评分后压缩，失败自动回退</option></select></label>
      <label>评分模型<select id="catalog-compact-model"><option value="">沿用旧 Jev 凭证配置</option>${ref && !choices.some(same) ? '<option value="missing" selected>绑定已失效，请重新选择</option>' : ""}${choices.map((c, i) => `<option value="${i}" ${same(c) ? "selected" : ""}>${esc(c.label)}</option>`).join("")}</select></label></div>
      <p class="muted">选择模型后使用其厂家地址与分组 Key，不受旧 TYPESAFE_API_KEY 覆盖。Jev 不会出现在聊天角色或聊天模型列表中。</p>
      <details><summary>评分预算与回退参数</summary><div class="catalog-fields">
      ${budget("maxStateTokens", "状态预算（token）", 20000)}${budget("maxRequestTokens", "请求预算（token）", 28000)}
      <label>保留阈值（0–1）<input data-jev-setting="keepThreshold" type="number" min="0" max="1" step="0.05" value="${esc(raw.keepThreshold ?? 0.5)}"></label>
      <label>最近消息保留数<input data-jev-setting="preserveRecentMessages" type="number" min="2" max="64" step="1" value="${esc(raw.preserveRecentMessages ?? 8)}"></label>
      <label>单次超时（毫秒）<input data-jev-setting="requestTimeoutMs" type="number" min="100" max="10000" step="100" value="${esc(raw.requestTimeoutMs ?? 3000)}"></label>
      <label>总超时（毫秒）<input data-jev-setting="totalTimeoutMs" type="number" min="100" max="20000" step="100" value="${esc(raw.totalTimeoutMs ?? 6000)}"></label>
      </div><p class="muted">这是本地调用预算，不是模型上下文上限。状态预算 1–25 K，请求预算 2–30 K，状态预算须更小；单次超时不超过总超时。</p></details>`;
    const edit = () => {
      cfg.compaction ||= {};
      cfg.compaction.jev ||= {};
      return cfg.compaction.jev;
    };
    bind(
      "catalog-compact-mode",
      (e) => {
        cfg.compaction ||= {};
        if (e.target.value) cfg.compaction.mode = e.target.value;
        else delete cfg.compaction.mode;
        mark();
      },
      "change",
    );
    bind(
      "catalog-compact-model",
      (e) => {
        const raw = edit(),
          chosen = choices[Number(e.target.value)];
        if (e.target.value === "") delete raw.modelRef;
        else if (chosen) {
          const { label, ...ref } = chosen;
          raw.modelRef = ref;
          cfg.compaction.mode = "jev";
        }
        mark();
        renderJevUsage();
      },
      "change",
    );
    $("catalog-jev")
      .querySelectorAll("[data-jev-budget]")
      .forEach((input) => {
        const key = input.dataset.jevBudget,
          unit = $("catalog-jev").querySelector(`[data-jev-unit="${key}"]`);
        const update = () => {
          const raw = edit();
          if (input.value === "") delete raw[key];
          else raw[key] = Math.round(Number(input.value) * Number(unit.value));
          mark();
        };
        input.oninput = update;
        unit.onchange = update;
      });
    $("catalog-jev")
      .querySelectorAll("[data-jev-setting]")
      .forEach((input) => {
        input.oninput = () => {
          const raw = edit();
          if (input.value === "") delete raw[input.dataset.jevSetting];
          else raw[input.dataset.jevSetting] = Number(input.value);
          mark();
        };
      });
  }

  function roles() {
    renderJevUsage();
    const choices = [];
    for (const [a, v] of Object.entries(cfg.providers))
      for (const [b, w] of Object.entries(v.groups))
        for (const m of w.models)
          if (m.id && !isJev(m, v))
            choices.push({
              provider: a,
              group: b,
              model: m.id,
              label: `${v.name || a} / ${w.name || b} / ${m.name || m.id} (${m.id})`,
            });
    $("catalog-roles").innerHTML = [
      ...new Set([
        "default",
        "worker",
        "adapter",
        "explorer",
        "plan",
        "advisor",
        "verifier",
        ...Object.keys(cfg.roles),
      ]),
    ]
      .map((role) => {
        const r = cfg.roles[role];
        return `<label>${esc(role)}<select data-role="${esc(role)}"><option value="">${role === "default" ? "请选择默认模型" : "跟随默认模型"}</option>${choices.map((c, i) => `<option value="${i}" ${r?.provider === c.provider && (r.group || "default") === c.group && r.model === c.model ? "selected" : ""}>${esc(c.label)}</option>`).join("")}</select></label>`;
      })
      .join("");
    $("catalog-roles")
      .querySelectorAll("select")
      .forEach(
        (s) =>
          (s.onchange = () => {
            if (s.value === "") delete cfg.roles[s.dataset.role];
            else {
              const { label, ...r } = choices[Number(s.value)];
              cfg.roles[s.dataset.role] = {
                ...cfg.roles[s.dataset.role],
                ...r,
              };
            }
            mark();
            if (g()) models();
          }),
      );
  }
  async function fetchModels() {
    if (busy) return;
    busy = true;
    const controls = [...root.querySelectorAll("input,select,button")].map(
      (el) => ({ el, disabled: el.disabled }),
    );
    controls.forEach(({ el }) => (el.disabled = true));
    const v = p(),
      w = g(),
      button = $("catalog-fetch");
    button.disabled = true;
    status("正在使用此分组凭证获取模型…");
    try {
      const result = await rpc("llm.catalogModels", {
        provider: pid,
        group: gid,
        baseUrl: v.baseUrl,
        apiKey: w.apiKey,
      });
      let added = 0;
      for (const id of result.models)
        if (!w.models.some((m) => m.id === id)) {
          w.models.push({ id, name: id });
          added++;
        }
      mark();
      if (g() === w) groupEditor();
      roles();
      status(`已导入 ${added} 个模型，保存后生效`);
    } catch (e) {
      status(e.message, true);
    } finally {
      busy = false;
      controls.forEach(({ el, disabled }) => (el.disabled = disabled));
      button.disabled = false;
    }
  }
  async function save() {
    if (busy) return;
    busy = true;
    const controls = [...root.querySelectorAll("input,select,button")].map(
      (el) => ({ el, disabled: el.disabled }),
    );
    controls.forEach(({ el }) => (el.disabled = true));
    try {
      data = await rpc("llm.saveCatalog", {
        config: cfg,
        revision: data.revision,
      });
      cfg = data.config;
      dirty = false;
      render();
      status("已保存，模型选用和在线会话已更新");
    } catch (e) {
      status(e.message, true);
    } finally {
      busy = false;
      controls.forEach(({ el, disabled }) => (el.disabled = disabled));
      $("catalog-save").disabled = false;
    }
  }
  window.addEventListener("beforeunload", (e) => {
    if (dirty && root && !root.classList.contains("hidden")) {
      e.preventDefault();
      e.returnValue = "";
    }
  });
  return { open };
})();
