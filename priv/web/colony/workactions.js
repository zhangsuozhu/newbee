// 工作项的两个通用动作：「不再提醒」和「结束工作」。
//
// 工作卡（taskcard.js / workflow.js）共用这一份实现；调用方传 colonyId，并在成功后刷新自己的视图。
// 宿主侧栏（app.js）是普通脚本，只复用 attention 策略（workview.js），这两个 RPC 自己发。
import { rpc, toast } from "./api.js";
import { form } from "./forms.js";

// 只有执行器已经不在、又进不了终态的工作才允许人结束；正在跑的先用卡片上的「立即中止」。
export function canAbandon(task) {
  return !!task && ["pending", "claimed", "blocked"].includes(task.status);
}


export async function toggleDismiss(colonyId, task, dismissed) {
  await rpc(dismissed ? "colony.work.restore" : "colony.work.dismiss", { colonyId, taskId: task.id });
  toast(dismissed ? "已恢复提醒" : "已设为不再提醒；工作有新进展时会自动回来");
}

export async function abandonWork(colonyId, task) {
  const input = await form(
    "结束这项工作",
    [{
      name: "note",
      label: "原因（可选）",
      multiline: true,
      help: "工作会标记为已取消并移出待办；已发生的文件修改与外部操作不会撤回，历史记录保留。"
    }],
    "结束工作"
  );
  if (!input) return false;
  await rpc("colony.work.abandon", { colonyId, taskId: task.id, note: input.note });
  toast("已结束这项工作");
  return true;
}
