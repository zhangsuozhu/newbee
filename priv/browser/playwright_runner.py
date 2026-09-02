#!/usr/bin/env python3
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

MAX_STRING = 64 * 1024
MAX_LIST = 100
MAX_DEPTH = 8
DEFAULT_TIMEOUT = 30_000


class RunnerFailure(Exception):
    def __init__(self, code, message, **details):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details


def get_value(mapping, name, default=None):
    if not isinstance(mapping, dict):
        return default
    return mapping.get(name, default)


def as_int(value, default, minimum=0, maximum=120_000):
    try:
        result = int(value)
    except (TypeError, ValueError):
        return default
    return max(minimum, min(result, maximum))


def as_bool(value, default=False):
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "on")
    return bool(value)


def trim_value(value, depth=0):
    if depth > MAX_DEPTH:
        return "[max depth]"
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, bytes):
        return {"encoding": "base64", "data": base64.b64encode(value).decode("ascii")}
    if isinstance(value, str):
        if len(value) <= MAX_STRING:
            return value
        return value[:MAX_STRING] + "… [truncated]"
    if isinstance(value, dict):
        items = list(value.items())[:MAX_LIST]
        result = {str(key): trim_value(item, depth + 1) for key, item in items}
        if len(value) > MAX_LIST:
            result["__truncated__"] = True
        return result
    if isinstance(value, (list, tuple)):
        result = [trim_value(item, depth + 1) for item in list(value)[:MAX_LIST]]
        if len(value) > MAX_LIST:
            result.append("… [truncated]")
        return result
    return trim_value(str(value), depth + 1)


def path_is_inside(path, base):
    try:
        return os.path.commonpath([str(path), str(base)]) == str(base)
    except ValueError:
        return False


def safe_path(value, default_name):
    raw = default_name if value in (None, "") else str(value)
    if "\x00" in raw:
        raise RunnerFailure("invalid_path", "path contains a NUL byte")
    candidate = Path(os.path.expanduser(raw))
    if not candidate.is_absolute():
        candidate = Path.cwd() / candidate
    candidate = candidate.resolve()
    bases = [Path.cwd().resolve(), (Path.home() / ".newbee").resolve(), Path("/tmp").resolve()]
    if not any(path_is_inside(candidate, base) for base in bases):
        raise RunnerFailure(
            "path_out_of_bounds",
            "browser artifact paths must be inside the project, ~/.newbee, or /tmp",
            path=str(candidate),
        )
    candidate.parent.mkdir(parents=True, exist_ok=True)
    return candidate


def safe_input_path(value):
    raw = str(value)
    if "\x00" in raw:
        raise RunnerFailure("invalid_path", "path contains a NUL byte")
    candidate = Path(os.path.expanduser(raw))
    if not candidate.is_absolute():
        candidate = Path.cwd() / candidate
    candidate = candidate.resolve()
    bases = [Path.cwd().resolve(), (Path.home() / ".newbee").resolve(), Path("/tmp").resolve()]
    if not any(path_is_inside(candidate, base) for base in bases):
        raise RunnerFailure(
            "path_out_of_bounds",
            "browser input paths must be inside the project, ~/.newbee, or /tmp",
            path=str(candidate),
        )
    return candidate




def trusted_executable(value):
    raw = str(value)
    if "\x00" in raw:
        raise RunnerFailure("invalid_executable", "executable_path contains a NUL byte")
    candidate = Path(os.path.expanduser(raw))
    if not candidate.is_absolute():
        raise RunnerFailure("invalid_executable", "executable_path must be absolute")
    candidate = candidate.resolve()
    allowed_roots = [
        Path("/usr/bin").resolve(),
        Path("/usr/local/bin").resolve(),
        Path("/opt/google/chrome").resolve(),
        (Path.home() / ".cache" / "ms-playwright").resolve(),
    ]
    name = candidate.name.lower()
    if not any(path_is_inside(candidate, root) for root in allowed_roots) or not any(token in name for token in ("chrome", "chromium", "firefox", "webkit")):
        raise RunnerFailure("invalid_executable", "executable_path must be a known browser binary")
    if not candidate.is_file() or not os.access(candidate, os.X_OK):
        raise RunnerFailure("browser_runtime_missing", "browser executable does not exist or is not executable", path=str(candidate))
    return candidate

def profile_path(request):
    profile = get_value(request, "profile")
    if profile in (None, ""):
        return None
    slug = str(profile).strip()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", slug):
        raise RunnerFailure("invalid_profile", "profile must be a short name, not a filesystem path")
    path = (Path.home() / ".newbee" / "browser" / "profiles" / slug).resolve()
    path.mkdir(parents=True, exist_ok=True)
    return path


def action_list(request, backend):
    actions = get_value(request, "actions")
    if actions is None:
        if backend == "screen":
            return [{"action": "screenshot"}]
        url = get_value(request, "url")
        if url:
            return [{"action": "goto", "url": url}, {"action": "snapshot"}]
        return [{"action": "snapshot"}]
    if isinstance(actions, dict):
        return [actions]
    if isinstance(actions, str):
        return [{"action": actions}]
    if not isinstance(actions, list):
        raise RunnerFailure("invalid_actions", "actions must be a list, map, or action name")
    return actions


def action_name(action):
    if isinstance(action, str):
        return action.strip().lower()
    if isinstance(action, dict):
        value = action.get("action", action.get("op", ""))
        return str(value).strip().lower()
    raise RunnerFailure("invalid_action", "each action must be a map or string")


def action_timeout(action, default):
    if not isinstance(action, dict):
        return default
    return as_int(action.get("timeout"), default, 0, 120_000)


def option_value(action, name, default=None):
    if not isinstance(action, dict):
        return default
    return action.get(name, default)


def locator_for(page, action):
    selector = option_value(action, "selector", option_value(action, "target"))
    if selector is None:
        raise RunnerFailure("missing_selector", "this browser action requires selector")
    selector = str(selector)
    frame_selector = option_value(action, "frame")
    base = page.frame_locator(str(frame_selector)) if frame_selector else page
    by = str(option_value(action, "by", "css")).lower()
    exact = as_bool(option_value(action, "exact"), False)

    if by in ("css", "selector"):
        locator = base.locator(selector)
    elif by == "xpath":
        locator = base.locator(selector if selector.startswith("xpath=") else "xpath=" + selector)
    elif by == "id":
        locator = base.locator(selector if selector.startswith("#") else "#" + selector)
    elif by == "text":
        locator = base.get_by_text(selector, exact=exact)
    elif by == "role":
        name = option_value(action, "name")
        locator = base.get_by_role(selector, name=name, exact=exact) if name is not None else base.get_by_role(selector)
    elif by == "label":
        locator = base.get_by_label(selector, exact=exact)
    elif by == "placeholder":
        locator = base.get_by_placeholder(selector, exact=exact)
    elif by in ("alt", "alt_text"):
        locator = base.get_by_alt_text(selector, exact=exact)
    elif by == "title":
        locator = base.get_by_title(selector, exact=exact)
    elif by in ("test_id", "testid"):
        locator = base.get_by_test_id(selector)
    else:
        raise RunnerFailure("invalid_locator", "unknown locator strategy", by=by)

    if "nth" in action:
        locator = locator.nth(as_int(action.get("nth"), 0, 0, 100_000))
    return locator


def response_info(response):
    if response is None:
        return None
    try:
        return {"status": response.status, "url": response.url}
    except Exception:
        return None


def text_snapshot(page, timeout):
    body = page.locator("body")
    text = body.inner_text(timeout=timeout) if body else ""
    links = page.locator("a").evaluate_all(
        "els => els.slice(0, 100).map(a => ({text: (a.innerText || a.textContent || '').trim(), href: a.href}))"
    )
    return {"url": page.url, "title": page.title(), "text": trim_value(text), "links": trim_value(links)}


def storage_action(page, action):
    scope = str(option_value(action, "scope", "local")).lower()
    if scope not in ("local", "localstorage", "session", "sessionstorage"):
        raise RunnerFailure("invalid_storage_scope", "scope must be local or session")
    mode = str(option_value(action, "mode", "get")).lower()
    script = '''
      ({scope, mode, key, value}) => {
        const store = scope === 'session' ? window.sessionStorage : window.localStorage;
        if (mode === 'get') {
          const result = {};
          for (let i = 0; i < store.length; i++) {
            const k = store.key(i);
            result[k] = store.getItem(k);
          }
          return result;
        }
        if (mode === 'clear') { store.clear(); return null; }
        if (mode === 'remove') { store.removeItem(key); return null; }
        store.setItem(key, String(value));
        return store.getItem(key);
      }
    '''
    payload = {
        "scope": "session" if scope.startswith("session") else "local",
        "mode": mode,
        "key": option_value(action, "key"),
        "value": option_value(action, "value", ""),
    }
    return page.evaluate(script, payload)


def page_frame(page, action):
    frame_name = option_value(action, "frame_name")
    frame_url = option_value(action, "frame_url")
    if frame_name is None and frame_url is None:
        return page
    for frame in page.frames:
        if frame_name is not None and frame.name == str(frame_name):
            return frame
        if frame_url is not None and str(frame_url) in frame.url:
            return frame
    raise RunnerFailure("frame_not_found", "no frame matched the requested name or URL")


def dispatch_playwright(state, action):
    if isinstance(action, str):
        action = {"action": action}
    if not isinstance(action, dict):
        raise RunnerFailure("invalid_action", "each action must be a map or string")
    name = action_name(action)
    page = state["page"]
    context = state["context"]
    timeout = action_timeout(action, state["timeout"])
    wait_until = str(option_value(action, "wait_until", "domcontentloaded"))

    if name in ("goto", "navigate", "open"):
        url = option_value(action, "url")
        if not url:
            raise RunnerFailure("missing_url", "goto requires url")
        kwargs = {"wait_until": wait_until, "timeout": timeout}
        if option_value(action, "referer"):
            kwargs["referer"] = str(action["referer"])
        response = page.goto(str(url), **kwargs)
        return {"url": page.url, "response": response_info(response)}
    if name == "reload":
        response = page.reload(wait_until=wait_until, timeout=timeout)
        return {"url": page.url, "response": response_info(response)}
    if name in ("back", "go_back"):
        response = page.go_back(wait_until=wait_until, timeout=timeout)
        return {"url": page.url, "response": response_info(response)}
    if name in ("forward", "go_forward"):
        response = page.go_forward(wait_until=wait_until, timeout=timeout)
        return {"url": page.url, "response": response_info(response)}
    if name in ("click", "dblclick", "double_click"):
        if "x" in action and "y" in action and option_value(action, "selector") is None:
            count = 2 if name != "click" else 1
            page.mouse.click(float(action["x"]), float(action["y"]), click_count=count, delay=action.get("delay"))
            return {"clicked": True, "x": action["x"], "y": action["y"]}
        locator = locator_for(page, action)
        kwargs = {"timeout": timeout}
        for key in ("button", "click_count", "delay", "force", "no_wait_after", "trial"):
            if key in action:
                kwargs[key] = action[key]
        if "position" in action:
            kwargs["position"] = action["position"]
        if "modifiers" in action:
            kwargs["modifiers"] = action["modifiers"]
        if name in ("dblclick", "double_click"):
            locator.dblclick(**kwargs)
        else:
            locator.click(**kwargs)
        return {"clicked": True}
    if name in ("fill", "set_value"):
        locator_for(page, action).fill(str(option_value(action, "value", "")), timeout=timeout)
        return {"filled": True}
    if name in ("type", "insert_text"):
        locator = locator_for(page, action)
        text = str(option_value(action, "text", option_value(action, "value", "")))
        delay = option_value(action, "delay") or 0
        if hasattr(locator, "press_sequentially"):
            locator.press_sequentially(text, delay=delay, timeout=timeout)
        else:
            locator.type(text, delay=delay, timeout=timeout)
        return {"typed": len(text)}
    if name in ("press", "key_press"):
        key = option_value(action, "key", option_value(action, "keys"))
        if key is None:
            raise RunnerFailure("missing_key", "press requires key")
        if option_value(action, "selector") is None:
            page.keyboard.press(str(key))
        else:
            locator_for(page, action).press(str(key), timeout=timeout)
        return {"pressed": key}
    if name in ("select", "select_option"):
        values = option_value(action, "values", option_value(action, "value"))
        selected = locator_for(page, action).select_option(values, timeout=timeout)
        return {"selected": selected}
    if name == "check":
        locator_for(page, action).check(timeout=timeout, force=as_bool(option_value(action, "force"), False))
        return {"checked": True}
    if name == "uncheck":
        locator_for(page, action).uncheck(timeout=timeout, force=as_bool(option_value(action, "force"), False))
        return {"unchecked": True}
    if name in ("hover", "move_to"):
        locator_for(page, action).hover(timeout=timeout, force=as_bool(option_value(action, "force"), False))
        return {"hovered": True}
    if name == "focus":
        locator_for(page, action).focus(timeout=timeout)
        return {"focused": True}
    if name in ("clear", "empty"):
        locator_for(page, action).fill("", timeout=timeout)
        return {"cleared": True}
    if name in ("mouse_move", "move"):
        page.mouse.move(float(action["x"]), float(action["y"]), steps=as_int(action.get("steps"), 1, 1, 100))
        return {"moved": True}
    if name in ("mouse_click", "click_at"):
        page.mouse.click(float(action["x"]), float(action["y"]), button=action.get("button", "left"), click_count=as_int(action.get("click_count"), 1, 1, 3))
        return {"clicked": True}
    if name in ("scroll", "wheel"):
        if option_value(action, "selector") is not None:
            locator_for(page, action).scroll_into_view_if_needed(timeout=timeout)
        if "x" in action and "y" in action and "delta_y" not in action and "delta_x" not in action:
            page.mouse.wheel(float(action["x"]), float(action["y"]))
        else:
            page.mouse.wheel(float(action.get("delta_x", 0)), float(action.get("delta_y", action.get("amount", 600))))
        return {"scrolled": True}
    if name in ("wait", "sleep"):
        if "ms" in action or "milliseconds" in action:
            page.wait_for_timeout(as_int(action.get("ms", action.get("milliseconds")), 0, 0, 120_000))
        if option_value(action, "selector") is not None:
            page.wait_for_selector(str(action["selector"]), state=action.get("state", "visible"), timeout=timeout)
        if option_value(action, "url") is not None:
            page.wait_for_url(str(action["url"]), wait_until=wait_until, timeout=timeout)
        if option_value(action, "load_state") is not None:
            page.wait_for_load_state(str(action["load_state"]), timeout=timeout)
        if option_value(action, "function") is not None:
            page.wait_for_function(str(action["function"]), timeout=timeout)
        return {"waited": True}
    if name in ("evaluate", "eval", "javascript"):
        expression = option_value(action, "expression", option_value(action, "script"))
        if not expression:
            raise RunnerFailure("missing_expression", "evaluate requires expression")
        return page_frame(page, action).evaluate(str(expression), option_value(action, "arg"))
    if name in ("title", "get_title"):
        return page.title()
    if name in ("url", "get_url"):
        return page.url
    if name in ("content", "page_content"):
        return page.content()
    if name in ("snapshot", "inspect"):
        return text_snapshot(page, timeout)
    if name in ("text", "inner_text"):
        return locator_for(page, action).inner_text(timeout=timeout)
    if name in ("inner_html", "html"):
        return locator_for(page, action).inner_html(timeout=timeout)
    if name in ("value", "input_value"):
        return locator_for(page, action).input_value(timeout=timeout)
    if name in ("attribute", "get_attribute"):
        attr = option_value(action, "name", option_value(action, "attribute"))
        if attr is None:
            raise RunnerFailure("missing_attribute", "attribute requires name")
        return locator_for(page, action).get_attribute(str(attr), timeout=timeout)
    if name == "count":
        return locator_for(page, action).count()
    if name in ("visible", "is_visible"):
        return locator_for(page, action).is_visible(timeout=timeout)
    if name in ("enabled", "is_enabled"):
        return locator_for(page, action).is_enabled(timeout=timeout)
    if name in ("bounds", "bounding_box"):
        return locator_for(page, action).bounding_box(timeout=timeout)
    if name in ("links", "list_links"):
        return page.locator("a").evaluate_all(
            "els => els.map(a => ({text: (a.innerText || a.textContent || '').trim(), href: a.href, target: a.target}))"
        )
    if name in ("select_text", "select_all_text"):
        locator_for(page, action).select_text(timeout=timeout)
        return {"selected": True}
    if name in ("set_content", "content_html"):
        html = option_value(action, "html", option_value(action, "content", ""))
        page.set_content(str(html), wait_until=wait_until, timeout=timeout)
        return {"content_set": True, "url": page.url}
    if name in ("set_viewport", "viewport"):
        viewport = option_value(action, "viewport", action)
        if not isinstance(viewport, dict) or "width" not in viewport or "height" not in viewport:
            raise RunnerFailure("invalid_viewport", "set_viewport requires width and height")
        page.set_viewport_size({"width": as_int(viewport["width"], 1280, 1, 8_000), "height": as_int(viewport["height"], 720, 1, 8_000)})
        return {"viewport": page.viewport_size}

    if name in ("drag", "drag_and_drop"):
        source = option_value(action, "source", option_value(action, "source_selector"))
        target = option_value(action, "target_selector", option_value(action, "destination"))
        if source is None or target is None:
            raise RunnerFailure("missing_drag_target", "drag requires source and target_selector")
        page.drag_and_drop(str(source), str(target), timeout=timeout)
        return {"dragged": True}
    if name in ("bring_to_front", "activate"):
        page.bring_to_front()
        return {"active": True}

    if name in ("screenshot", "capture_screenshot"):
        default = "screenshot-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + ".png"
        path = safe_path(option_value(action, "path", option_value(action, "output")), default)
        kwargs = {"path": str(path), "full_page": as_bool(option_value(action, "full_page"), False)}
        if isinstance(action.get("mask"), list):
            kwargs["mask"] = [page.locator(str(item)) for item in action["mask"]]
        selector = option_value(action, "selector")
        if selector is not None:
            kwargs.pop("full_page", None)
            locator_for(page, action).screenshot(**kwargs)
        else:
            page.screenshot(**kwargs)
        return {"path": str(path), "bytes": path.stat().st_size}


    if name in ("pdf", "save_pdf"):
        default = "page-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + ".pdf"
        path = safe_path(option_value(action, "path", option_value(action, "output")), default)
        kwargs = {"path": str(path), "print_background": as_bool(option_value(action, "print_background"), True)}
        for key in ("format", "landscape", "scale", "margin", "page_ranges", "prefer_css_page_size"):
            if key in action:
                kwargs[key] = action[key]
        page.pdf(**kwargs)
        return {"path": str(path), "bytes": path.stat().st_size}
    if name in ("new_tab", "new_page"):
        new_page = context.new_page()
        if new_page not in state["pages"]:
            state["pages"].append(new_page)
        state["page"] = new_page

        if option_value(action, "url"):
            new_page.goto(str(action["url"]), wait_until=wait_until, timeout=timeout)
        return {"index": len(state["pages"]) - 1, "url": new_page.url}
    if name in ("switch_tab", "switch_page"):
        index = option_value(action, "index")
        if index is not None:
            index = as_int(index, -1, -1, len(state["pages"]) - 1)
            if index < 0 or index >= len(state["pages"]):
                raise RunnerFailure("invalid_tab", "tab index is out of range")
            state["page"] = state["pages"][index]
            return {"index": index, "url": state["page"].url}
        url_part = str(option_value(action, "url", ""))
        for index, candidate in enumerate(state["pages"]):
            if url_part in candidate.url:
                state["page"] = candidate
                return {"index": index, "url": candidate.url}
        raise RunnerFailure("tab_not_found", "no tab matched")
    if name in ("close_tab", "close_page"):
        if len(state["pages"]) <= 1:
            raise RunnerFailure("last_tab", "cannot close the last tab")
        index = state["pages"].index(page)
        page.close()
        state["pages"].pop(index)
        state["page"] = state["pages"][max(0, index - 1)]
        return {"closed": index, "active": state["pages"].index(state["page"])}
    if name in ("tabs", "pages"):
        return [{"index": i, "url": candidate.url, "title": candidate.title()} for i, candidate in enumerate(state["pages"])]
    if name in ("cookies", "get_cookies"):
        return context.cookies(action.get("urls"))
    if name in ("set_cookie", "set_cookies"):
        cookies = action.get("cookies", action.get("cookie"))
        if isinstance(cookies, dict):
            cookies = [cookies]
        if not isinstance(cookies, list):
            raise RunnerFailure("invalid_cookies", "cookies must be a map or list")
        context.add_cookies(cookies)
        return {"set": len(cookies)}
    if name in ("clear_cookies", "delete_cookies"):
        context.clear_cookies()
        return {"cleared": True}
    if name in ("storage", "web_storage"):
        return storage_action(page, action)
    if name in ("headers", "set_headers"):
        headers = action.get("headers")
        if not isinstance(headers, dict):
            raise RunnerFailure("invalid_headers", "headers must be a map")
        context.set_extra_http_headers({str(k): str(v) for k, v in headers.items()})
        return {"headers": list(headers.keys())}
    if name in ("permissions", "grant_permissions"):
        permissions = action.get("permissions", [])
        context.grant_permissions(permissions, origin=action.get("origin"))
        return {"permissions": permissions}
    if name in ("download", "save_download"):
        locator = locator_for(page, action)
        default = "download-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        path = safe_path(action.get("path", action.get("output")), default)
        with page.expect_download(timeout=timeout) as download_info:
            locator.click(timeout=timeout)
        download = download_info.value
        download.save_as(str(path))
        return {"path": str(path), "suggested_filename": download.suggested_filename, "bytes": path.stat().st_size}
    if name in ("upload", "set_input_files"):
        files = action.get("files", action.get("path"))
        if isinstance(files, (str, dict)):
            files = [files]
        if not isinstance(files, list):
            raise RunnerFailure("invalid_upload", "files must be a path or list of paths")
        safe_files = []
        for item in files:
            if isinstance(item, dict):
                safe_files.append(dict(item))
            else:
                safe_files.append(str(safe_input_path(item)))
        locator_for(page, action).set_input_files(safe_files, timeout=timeout)
        return {"uploaded": len(safe_files)}
    if name in ("browser_version", "version"):
        return {"browser": state["browser_name"], "version": state["browser"].version if state["browser"] is not None else "persistent"}
    if name in ("close", "close_browser"):
        state["closed"] = True
        return {"closed": True}
    raise RunnerFailure("unsupported_action", "unsupported Playwright browser action", action=name)



def run_playwright(request):
    try:
        from playwright.sync_api import Error as PlaywrightError
        from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
        from playwright.sync_api import sync_playwright
    except Exception as exc:
        raise RunnerFailure("missing_playwright", "Python Playwright is not available", detail=str(exc))

    browser = None
    context = None
    timeout = as_int(get_value(request, "timeout"), DEFAULT_TIMEOUT, 500, 120_000)
    browser_name = str(get_value(request, "browser", "chromium")).lower()
    if browser_name not in ("chromium", "firefox", "webkit"):
        raise RunnerFailure("invalid_browser", "browser must be chromium, firefox, or webkit")

    try:
        with sync_playwright() as playwright:
            browser_type = getattr(playwright, browser_name)
            launch_options = {
                "headless": as_bool(get_value(request, "headless"), True),
                "timeout": as_int(get_value(request, "launch_timeout"), min(timeout, 30_000), 500, 120_000),
            }
            channel = get_value(request, "channel")
            executable_path = get_value(request, "executable_path")
            if channel:
                launch_options["channel"] = str(channel)
            if executable_path:
                launch_options["executable_path"] = str(trusted_executable(executable_path))
            if not channel and not executable_path and browser_name == "chromium":
                bundled = Path(browser_type.executable_path)
                if not bundled.is_file():
                    for fallback in ("/opt/google/chrome/chrome", "/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser"):
                        candidate = Path(fallback)
                        if candidate.is_file() and os.access(candidate, os.X_OK):
                            launch_options["executable_path"] = str(candidate)
                            break
            if not channel and not executable_path and "executable_path" not in launch_options and not Path(browser_type.executable_path).is_file():
                raise RunnerFailure("browser_runtime_missing", "Playwright browser is not installed; run `playwright install " + browser_name + "`")
            args = get_value(request, "args")

            if isinstance(args, list):
                launch_options["args"] = [str(item) for item in args[:32]]
            else:
                launch_options["args"] = [
                    "--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu",
                    "--disable-background-networking", "--disable-breakpad", "--disable-crash-reporter",
                    "--no-first-run", "--no-default-browser-check",
                ]

            context_options = {}
            viewport = get_value(request, "viewport", get_value(request, "viewport_size"))
            if isinstance(viewport, str) and "," in viewport:
                width, height = viewport.split(",", 1)
                viewport = {"width": as_int(width, 1280, 1, 8_000), "height": as_int(height, 720, 1, 8_000)}
            if isinstance(viewport, dict) and "width" in viewport and "height" in viewport:
                context_options["viewport"] = {
                    "width": as_int(viewport["width"], 1280, 1, 8_000),
                    "height": as_int(viewport["height"], 720, 1, 8_000),
                }
            for source, target in (("locale", "locale"), ("timezone", "timezone_id"), ("timezone_id", "timezone_id"), ("user_agent", "user_agent"), ("color_scheme", "color_scheme"), ("base_url", "base_url")):
                if get_value(request, source) is not None:
                    context_options[target] = get_value(request, source)
            if "ignore_https_errors" in request:
                context_options["ignore_https_errors"] = as_bool(request["ignore_https_errors"])
            if isinstance(get_value(request, "geolocation"), dict):
                context_options["geolocation"] = request["geolocation"]
            if isinstance(get_value(request, "permissions"), list):
                context_options["permissions"] = request["permissions"]
            if isinstance(get_value(request, "extra_http_headers"), dict):
                context_options["extra_http_headers"] = {str(k): str(v) for k, v in request["extra_http_headers"].items()}
            if get_value(request, "storage_state"):
                context_options["storage_state"] = str(safe_input_path(request["storage_state"]))

            profile = profile_path(request)
            if profile is not None:
                context = browser_type.launch_persistent_context(str(profile), **launch_options, **context_options)
            else:
                browser = browser_type.launch(**launch_options)
                context = browser.new_context(**context_options)
            context.set_default_timeout(timeout)
            context.set_default_navigation_timeout(timeout)
            page = context.new_page()
            state = {"browser": browser, "browser_name": browser_name, "context": context, "page": page, "pages": [page], "timeout": timeout, "closed": False}

            dialog_mode = get_value(request, "dialog")
            mode = str(dialog_mode).lower() if dialog_mode else "accept"

            def handle_dialog(dialog):
                if mode in ("dismiss", "close"):
                    dialog.dismiss()
                elif mode in ("prompt", "accept_prompt"):
                    dialog.accept(str(get_value(request, "dialog_text", "")))
                else:
                    dialog.accept()

            def track_page(new_page):
                if new_page not in state["pages"]:
                    state["pages"].append(new_page)
                if dialog_mode:
                    new_page.on("dialog", handle_dialog)

            context.on("page", track_page)
            if dialog_mode:
                page.on("dialog", handle_dialog)

            if get_value(request, "url") and "actions" in request:
                page.goto(str(request["url"]), wait_until=str(get_value(request, "wait_until", "domcontentloaded")), timeout=timeout)

            results = []
            for index, action in enumerate(action_list(request, "playwright")):
                if state["closed"]:
                    break
                try:
                    results.append({"action": action_name(action), "result": trim_value(dispatch_playwright(state, action))})
                except RunnerFailure as exc:
                    exc.details.setdefault("action_index", index)
                    raise
                except PlaywrightTimeoutError as exc:
                    raise RunnerFailure("timeout", "browser action timed out", action_index=index, detail=str(exc))
                except PlaywrightError as exc:
                    raise RunnerFailure("playwright_error", "browser action failed", action_index=index, detail=str(exc))
            saved = get_value(request, "save_storage")
            if saved:
                target = safe_path(saved, "storage-state.json")
                context.storage_state(path=str(target))
            active = state["page"]
            return {"backend": "playwright", "browser": browser_name, "url": active.url, "title": active.title(), "results": results}
    except RunnerFailure:
        raise
    except PlaywrightTimeoutError as exc:
        raise RunnerFailure("browser_launch_timeout", "browser launch or action timed out", detail=str(exc))
    except PlaywrightError as exc:
        raise RunnerFailure("browser_launch_failed", "Playwright could not start the browser", detail=str(exc))
    except FileNotFoundError as exc:
        raise RunnerFailure("browser_runtime_missing", "browser executable or helper file is missing", detail=str(exc))
    except Exception as exc:
        raise RunnerFailure("browser_failed", "browser automation failed", detail=str(exc))
    finally:
        if context is not None:
            try:
                context.close()
            except Exception:
                pass
        elif browser is not None:
            try:
                browser.close()
            except Exception:
                pass


SCREEN_KEY_ALIASES = {
    "enter": "Return", "return": "Return", "esc": "Escape", "escape": "Escape", "tab": "Tab",
    "backspace": "BackSpace", "delete": "Delete", "space": "space", "left": "Left", "right": "Right",
    "up": "Up", "down": "Down", "home": "Home", "end": "End", "pageup": "Page_Up", "pagedown": "Page_Down",
    "ctrl": "Control_L", "control": "Control_L", "alt": "Alt_L", "shift": "Shift_L", "meta": "Super_L", "super": "Super_L",
}
SCREEN_MODIFIERS = {"ctrl", "control", "alt", "shift", "meta", "super"}


def screen_windows():
    wmctrl = shutil.which("wmctrl")
    if wmctrl is None:
        raise RunnerFailure("screen_tool_missing", "wmctrl is required for screen browser control")
    result = subprocess.run([wmctrl, "-l"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    if result.returncode != 0:
        raise RunnerFailure("screen_window_query_failed", result.stderr.strip() or "wmctrl failed")
    windows = []
    for line in result.stdout.splitlines():
        parts = line.split(None, 3)
        if len(parts) >= 4:
            windows.append({"id": parts[0], "desktop": parts[1], "title": parts[3]})
    return windows


def choose_screen_window(request):
    requested_id = get_value(request, "window_id")
    if requested_id:
        value = str(requested_id)
        if value.lower() == "root" or re.fullmatch(r"0x[0-9a-fA-F]+|[0-9]+", value):
            return value
        raise RunnerFailure("invalid_window_id", "window_id must be root or an X11 hexadecimal ID")
    windows = screen_windows()
    title = str(get_value(request, "window_title", "")).casefold()
    if title:
        for item in windows:
            if title in item["title"].casefold():
                return item["id"]
    for item in windows:
        if "chrome" in item["title"].casefold() or "chromium" in item["title"].casefold():
            return item["id"]
    return None


def focus_screen_window(window_id):
    if not window_id or window_id == "root":
        return
    wmctrl = shutil.which("wmctrl")
    if wmctrl is None:
        raise RunnerFailure("screen_tool_missing", "wmctrl is required for screen browser control")
    result = subprocess.run([wmctrl, "-ia", str(window_id)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    if result.returncode != 0:
        raise RunnerFailure("screen_focus_failed", result.stderr.strip() or "could not focus window")


def screen_origin(window_id):
    if not window_id or window_id == "root":
        return 0, 0
    xwininfo = shutil.which("xwininfo")
    if xwininfo is None:
        return 0, 0
    result = subprocess.run([xwininfo, "-id", str(window_id)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    if result.returncode != 0:
        return 0, 0
    x_match = re.search(r"Absolute upper-left X:\s+(-?\\d+)", result.stdout)
    y_match = re.search(r"Absolute upper-left Y:\s+(-?\\d+)", result.stdout)
    return (int(x_match.group(1)) if x_match else 0, int(y_match.group(1)) if y_match else 0)


def x11_key_name(value):
    text = str(value)
    return SCREEN_KEY_ALIASES.get(text.lower(), text)


def x11_send_key(display_obj, value, down=True):
    from Xlib import X, XK
    from Xlib.ext import xtest

    name = x11_key_name(value)
    keysym = XK.string_to_keysym(name)
    if keysym == 0 and len(name) == 1:
        keysym = ord(name)
    keycode = display_obj.keysym_to_keycode(keysym)
    if keycode == 0:
        raise RunnerFailure("unsupported_key", "X11 could not map key", key=name)
    xtest.fake_input(display_obj, X.KeyPress if down else X.KeyRelease, keycode)


def x11_hotkey(display_obj, keys):
    if isinstance(keys, str):
        keys = [part for part in keys.split("+") if part]
    if not isinstance(keys, list) or not keys:
        raise RunnerFailure("invalid_hotkey", "hotkey requires a key list or Ctrl+key string")
    modifiers = [key for key in keys[:-1] if str(key).lower() in SCREEN_MODIFIERS]
    primary = keys[-1]
    for key in modifiers:
        x11_send_key(display_obj, key, True)
    x11_send_key(display_obj, primary, True)
    x11_send_key(display_obj, primary, False)
    for key in reversed(modifiers):
        x11_send_key(display_obj, key, False)
    display_obj.sync()


def x11_type_ascii(display_obj, text):
    if any(ord(char) > 127 for char in text):
        raise RunnerFailure("screen_unicode_unsupported", "screen backend types ASCII only; use Playwright for Unicode")
    shifted = set("~!@#$%^&*()_+{}|:\"<>") | {"?"}
    pairs = {
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
        "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\",
        ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
    }
    for char in text:
        if char == "\n":
            x11_hotkey(display_obj, ["Return"])
            continue
        if char == "\t":
            x11_hotkey(display_obj, ["Tab"])
            continue
        if char == " ":
            key, needs_shift = "space", False
        elif char.isupper() or char in shifted:
            key, needs_shift = pairs.get(char, char.lower()), True
        else:
            key, needs_shift = char, False
        if needs_shift:
            x11_send_key(display_obj, "Shift", True)
        x11_send_key(display_obj, key, True)
        x11_send_key(display_obj, key, False)
        if needs_shift:
            x11_send_key(display_obj, "Shift", False)
    display_obj.sync()


def screen_screenshot(path, window_id, timeout):
    tool = shutil.which("import")
    if tool:
        command = [tool, "-window", str(window_id or "root"), str(path)]
    else:
        tool = shutil.which("scrot")
        if not tool:
            raise RunnerFailure("screen_tool_missing", "ImageMagick import or scrot is required for screenshots")
        command = [tool, "-o", str(path)]
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=max(5, timeout / 1000))
    if result.returncode != 0:
        raise RunnerFailure("screen_screenshot_failed", result.stderr.strip() or "screen screenshot failed")
    return {"path": str(path), "bytes": path.stat().st_size, "window_id": window_id or "root"}


def dispatch_screen(state, action):
    if isinstance(action, str):
        action = {"action": action}
    if not isinstance(action, dict):
        raise RunnerFailure("invalid_action", "each action must be a map or string")
    name = action_name(action)
    timeout = action_timeout(action, state["timeout"])
    window_id = state["window_id"]

    if name in ("list_windows", "windows"):
        return screen_windows()
    if name in ("focus", "focus_window"):
        focus_screen_window(window_id)
        return {"focused": window_id}
    if name in ("screenshot", "capture_screenshot"):
        default = "screen-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + ".png"
        return screen_screenshot(safe_path(action.get("path", action.get("output")), default), window_id, timeout)
    if name in ("navigate", "goto", "open"):
        url = action.get("url")
        if not url:
            raise RunnerFailure("missing_url", "screen navigation requires url")
        from Xlib import display as xdisplay

        focus_screen_window(window_id)
        display_obj = xdisplay.Display()
        x11_hotkey(display_obj, ["Ctrl", "L"])
        x11_type_ascii(display_obj, str(url))
        x11_hotkey(display_obj, ["Return"])
        display_obj.close()
        time.sleep(as_int(action.get("wait_ms"), 500, 0, 120_000) / 1000)
        return {"navigated": str(url), "window_id": window_id}
    if name in ("click", "click_at", "double_click", "dblclick"):
        if "x" not in action or "y" not in action:
            raise RunnerFailure("missing_coordinates", "screen clicks require x and y")
        from Xlib import X, display as xdisplay
        from Xlib.ext import xtest

        focus_screen_window(window_id)
        x, y = float(action["x"]), float(action["y"])
        if as_bool(action.get("relative"), False) or as_bool(action.get("relative_to_window"), False):
            ox, oy = screen_origin(window_id)
            x, y = x + ox, y + oy
        display_obj = xdisplay.Display()
        xtest.fake_input(display_obj, X.MotionNotify, x=int(x), y=int(y))
        count = 2 if name in ("double_click", "dblclick") else as_int(action.get("click_count"), 1, 1, 3)
        for _ in range(count):
            xtest.fake_input(display_obj, X.ButtonPress, 1)
            xtest.fake_input(display_obj, X.ButtonRelease, 1)
            if count > 1:
                time.sleep(0.05)
        display_obj.sync()
        display_obj.close()
        return {"clicked": True, "x": x, "y": y}
    if name in ("scroll", "wheel"):
        from Xlib import X, display as xdisplay
        from Xlib.ext import xtest

        focus_screen_window(window_id)
        x, y = float(action.get("x", 0)), float(action.get("y", 0))
        if as_bool(action.get("relative"), False) or as_bool(action.get("relative_to_window"), False):
            ox, oy = screen_origin(window_id)
            x, y = x + ox, y + oy
        amount = as_int(action.get("amount", action.get("delta_y", 1)), 1, -20, 20)
        button = 4 if amount < 0 else 5
        display_obj = xdisplay.Display()
        xtest.fake_input(display_obj, X.MotionNotify, x=int(x), y=int(y))
        for _ in range(max(1, abs(amount))):
            xtest.fake_input(display_obj, X.ButtonPress, button)
            xtest.fake_input(display_obj, X.ButtonRelease, button)
        display_obj.sync()
        display_obj.close()
        return {"scrolled": amount}
    if name in ("press", "key_press"):
        key = action.get("key", action.get("keys"))
        if key is None:
            raise RunnerFailure("missing_key", "screen press requires key")
        from Xlib import display as xdisplay

        focus_screen_window(window_id)
        display_obj = xdisplay.Display()
        x11_hotkey(display_obj, key if isinstance(key, list) or "+" in str(key) else [key])
        display_obj.close()
        return {"pressed": key}
    if name in ("type", "write", "insert_text"):
        text = str(action.get("text", action.get("value", "")))
        from Xlib import display as xdisplay

        focus_screen_window(window_id)
        display_obj = xdisplay.Display()
        x11_type_ascii(display_obj, text)
        display_obj.close()
        return {"typed": len(text)}
    if name in ("wait", "sleep"):
        time.sleep(as_int(action.get("ms", action.get("milliseconds", 500)), 500, 0, 120_000) / 1000)
        return {"waited": True}
    raise RunnerFailure("unsupported_screen_action", "screen backend supports window, mouse, keyboard, navigation, and screenshot actions", action=name)


def run_screen(request):
    if not os.environ.get("DISPLAY"):
        raise RunnerFailure("display_unavailable", "screen backend requires an X11 DISPLAY")
    window_id = choose_screen_window(request)
    state = {"window_id": window_id, "timeout": as_int(get_value(request, "timeout"), DEFAULT_TIMEOUT, 500, 120_000)}
    results = []
    for index, action in enumerate(action_list(request, "screen")):
        try:
            results.append({"action": action_name(action), "result": trim_value(dispatch_screen(state, action))})
        except RunnerFailure as exc:
            exc.details.setdefault("action_index", index)
            raise
        except Exception as exc:
            raise RunnerFailure("screen_action_failed", "screen browser action failed", action_index=index, detail=str(exc))
    return {"backend": "screen", "window_id": window_id or "root", "results": results}


def run_request(request):
    if not isinstance(request, dict):
        raise RunnerFailure("invalid_request", "browser request must be a JSON object")
    backend = str(get_value(request, "backend", "playwright")).lower()
    if backend == "screen":
        return run_screen(request)
    if backend in ("playwright", "isolated"):
        return run_playwright(request)
    raise RunnerFailure("invalid_backend", "backend must be playwright or screen")


def emit(payload, exit_code=0):
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    return exit_code


def main():
    if len(sys.argv) != 2:
        return emit({"ok": False, "error": {"code": "invalid_arguments", "message": "expected one base64 JSON request"}}, 2)
    try:
        raw = base64.b64decode(sys.argv[1].encode("ascii"), validate=True)
        request = json.loads(raw.decode("utf-8"))
        return emit({"ok": True, "result": run_request(request)})
    except RunnerFailure as exc:
        error = {"code": exc.code, "message": exc.message}
        error.update(exc.details)
        return emit({"ok": False, "error": error}, 2)
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        return emit({"ok": False, "error": {"code": "invalid_request_encoding", "message": str(exc)}}, 2)
    except Exception as exc:
        return emit({"ok": False, "error": {"code": "runner_failed", "message": str(exc)}}, 2)


if __name__ == "__main__":
    sys.exit(main())
