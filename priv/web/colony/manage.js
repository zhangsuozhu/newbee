import {rpc, toast} from './api.js';
import {state, refresh, loadColonies, selectColony} from './store.js';
import {form} from './forms.js';

export async function renameColony() {
  const colony = state.data?.colony;
  if (!colony || !state.data?.can_manage) return;
  const value = await form('改名蜂群', [{name:'name',label:'新名称',value:colony.name || '',required:true,placeholder:'例如：研发蜂群'}], '保存');
  if (!value) return;
  try {
    await rpc('colony.rename', {colonyId:state.colonyId, name:value.name});
    toast('已改名');
    await loadColonies();
    await refresh();
  } catch (error) {toast(error.message || '改名失败', true);}
}

export async function dissolveColony() {
  const colony = state.data?.colony;
  if (!colony || !state.data?.can_manage) return;
  const value = await form('解散蜂群', [{name:'name',label:`输入蜂群名称「${colony.name}」`,required:true,matches:colony.name,help:'停止新的协作与成员访问，工作和成果记录保留。'}], '解散');
  if (!value) return;
  try {
    await rpc('colony.dissolve', {colonyId:state.colonyId});
    toast('已解散');
    await selectColony(null);
    await loadColonies();
    await refresh();
  } catch (error) {toast(error.message || '解散失败', true);}
}


export async function manage() {
  const owner = state.data?.can_manage;
  const options = owner ? [{value:'rename',label:'改名蜂群'}, {value:'invite',label:'邀请同事'}, {value:'environment',label:'邀请另一台 AI 环境'}, {value:'add',label:'添加本地 AI'}, {value:'remove',label:'移出成员'}, {value:'leave',label:'退出蜂群'}, {value:'dissolve',label:'解散蜂群'}] : [{value:'leave',label:'退出蜂群'}];
  const choice = await form('蜂群设置', [{name:'action',label:'要做什么',options}], '继续');
  if (!choice) return;
  try {
    if (choice.action === 'rename') return renameColony();

    if (choice.action === 'invite' || choice.action === 'environment') {
      const ai = choice.action === 'environment';
      const invite = await rpc('colony.invite.create', {colonyId:state.colonyId, kind:ai ? 'ai' : 'human'});
      const value = ai ? 'newbee-colony:' + btoa(JSON.stringify(invite)) : `${location.origin}/colony.html#invite=${encodeURIComponent(invite.code)}`;
      await form(ai ? '邀请另一台环境' : '邀请同事', [{name:'invite',label:ai ? '在另一台 newbee 的「加入蜂群」中粘贴' : '发送给同事的邀请链接', value, multiline:true, readonly:true, help:'一小时内有效，只能使用一次。只允许访问当前蜂群。'}], '关闭');
    } else if (choice.action === 'add') {
      const value = await form('添加本地 AI', [{name:'display',label:'名称',required:true,value:'研发助手'}, {name:'capabilities',label:'能力（逗号分隔）',value:'edit,shell,research'}], '添加');
      if (value) await rpc('colony.bee.add', {colonyId:state.colonyId, display:value.display, kind:'ai', capabilities:value.capabilities.split(',').map(s=>s.trim()).filter(Boolean), bindSession:false});
    } else if (choice.action === 'remove') {
      const members = (state.data?.members || []).filter(b => b.id !== state.data?.actor_bee_id);
      const value = await form('移出成员', [{name:'beeId',label:'成员',options:members.map(b=>({value:b.id,label:b.display})),help:'吊销访问。未完成的工作保留并等待重新安排，不自动重放外部操作。'}], '移出');
      if (value) await rpc('colony.bee.remove', {colonyId:state.colonyId, beeId:value.beeId});
    } else if (choice.action === 'leave') {
      const value = await form('退出蜂群', owner ? [{name:'handoverTo',label:'交接给哪位成员',options:(state.data?.members || []).filter(b=>b.kind==='human' && b.id!==state.data?.actor_bee_id).map(b=>({value:b.display,label:b.display})),required:true,help:'管理员退出前需要交接；已有工作和成果会保留。'}] : [], '退出');
      if (value) {await rpc('colony.bee.leave', {colonyId:state.colonyId, beeId:state.data.actor_bee_id, handoverTo:value.handoverTo}); await selectColony(null);}
    } else if (choice.action === 'dissolve') {
      return dissolveColony();
    }
    await loadColonies(); await refresh();
  } catch (error) {toast(error.message, true);}
}
export async function joinEnvironment() {
  const value = await form('加入蜂群', [{name:'invite',label:'环境邀请码',required:true,multiline:true}, {name:'display',label:'这台环境的名称',required:true}, {name:'cwd',label:'允许工作的本地项目目录',required:true,help:'远端工作只交给此环境。连接断开后在安全边界暂停，不自动接管未知结果。'}], '加入');
  if (!value) return;
  try {
    const invitation = JSON.parse(atob(value.invite.replace(/^newbee-colony:/,'')));
    const result = await rpc('colony.remote.join', {...invitation, display:value.display, cwd:value.cwd});
    await loadColonies(); await selectColony(result.colony.id);
  } catch (error) {toast(error.message || '邀请码无效',true);}
}
export async function redeemInvitation() {
  const code = new URLSearchParams(location.hash.slice(1)).get('invite');
  if (!code) return;
  const value = await form('加入蜂群', [{name:'display',label:'你的名字',required:true}], '加入');
  if (!value) return;
  const result = await rpc('colony.invite.redeem', {code, display:value.display});
  localStorage.setItem('newbee.token', result.token);
  history.replaceState(null, '', location.pathname);
  state.colonyId = result.colony.id;
}
export async function help() {
  await form('在蜂群里能做什么', [{name:'help',label:'直接说需求，也可以使用这些入口',value:'群聊：说要完成什么，系统选择一名负责人。\n@成员：指定负责人；@all 讨论：最多三名 AI 提方案。\n工作卡：查看进度和证据、补要求、答复并继续、请成员协作。\n暂停：可分别暂停全群 AI、某个 AI、某项工作；不会阻止人说话。\n点 AI：打开原来的对话界面，附件、模型和思考设置仍在那里。\n点同事：私聊。群设置：邀请、移出、退出和解散。',multiline:true,readonly:true}], '知道了');
}


