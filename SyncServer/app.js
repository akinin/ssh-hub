'use strict';
const $ = id => document.getElementById(id);
let me = null, data = null, csrf = '', epoch = 0, refreshing = false, writing = false, toastTimer, saveEditor = null;
const pages = {users:0,devices:0,storage:0};
const views = {
  overview:['Обзор','Облачная синхронизация и состояние хранилища'],
  users:['Пользователи','Учётные записи, права и доступ к облаку'],
  devices:['Устройства','Подключения приложений и браузеров'],
  statistics:['Статистика','Снимки, использование хранилища и обмен данными'],
  activity:['Журнал событий','Входы, синхронизация и административные действия'],
  account:['Учётная запись','Подключение приложения и безопасность входа']
};
const errors = {invalid_credentials:'Неверный логин или пароль.',unauthorized:'Сеанс завершён. Войди снова.',try_later:'Слишком много запросов. Попробуй немного позже.',
  invalid_username:'Логин: от 3 до 64 латинских букв, цифр, точек, дефисов и подчёркиваний.',invalid_password:'Пароль должен содержать от 12 до 1024 символов.',
  username_exists:'Этот логин уже занят.',user_limit:'Достигнут лимит учётных записей.',invalid_update:'Это изменение недоступно. Собственный пароль меняется в разделе «Учётная запись».',
  last_admin:'На сервере должен оставаться хотя бы один включённый администратор.',unknown_user:'Пользователь не найден.',invalid_role:'Неизвестная роль.',
  admin_required:'Действие доступно только администратору.',device_not_found:'Устройство не найдено или принадлежит другой учётной записи.',invalid_device:'Укажи корректное название устройства.',
  csrf:'Не удалось подтвердить запрос. Обнови страницу.',storage_unavailable:'Хранилище сервера временно недоступно. Попробуй позже.',proxy_required:'Подключись через основной HTTPS-адрес сервера.'};
function node(tag, attrs={}, children=[]) {
  const value=document.createElement(tag);
  for(const [key,item] of Object.entries(attrs)) {
    if(key==='text') value.textContent=item;
    else if(key==='class') value.className=item;
    else if(key==='data') Object.assign(value.dataset,item);
    else if(key==='hidden') value.hidden=item;
    else value.setAttribute(key,String(item));
  }
  for(const item of children) if(item!==null&&item!==undefined) value.append(item instanceof Node?item:document.createTextNode(String(item)));
  return value;
}
function icon(name) { const value=document.createElementNS('http://www.w3.org/2000/svg','svg'), use=document.createElementNS(value.namespaceURI,'use');use.setAttribute('href','#i-'+name);value.setAttribute('aria-hidden','true');value.append(use);return value; }
function button(text, action, id='', style='secondary') { return node('button',{type:'button',class:style,text,data:{action,id}}); }
function badge(text,style='') { return node('span',{class:'badge '+style,text}); }
function avatar(name) { return node('span',{class:'avatar',text:name.slice(0,2).toUpperCase()}); }
function bytes(value=0) { if(!value)return '0 Б';const units=['Б','КиБ','МиБ','ГиБ','ТиБ'];const index=Math.min(4,Math.floor(Math.log(value)/Math.log(1024)));return new Intl.NumberFormat('ru-RU',{maximumFractionDigits:index?1:0}).format(value/1024**index)+' '+units[index]; }
function number(value=0) {return new Intl.NumberFormat('ru-RU').format(value);}
function date(value,short=false) {return value?new Intl.DateTimeFormat('ru-RU',{day:'2-digit',month:'short',...(short?{}:{year:'numeric'}),hour:'2-digit',minute:'2-digit'}).format(new Date(value*1000)):'Ещё не было';}
function relative(value) { if(!value)return 'Ещё не было';const seconds=Date.now()/1000-value;if(seconds<60)return 'Только что';if(seconds<3600)return Math.floor(seconds/60)+' мин назад';if(seconds<86400)return Math.floor(seconds/3600)+' ч назад';return date(value,true); }
function detail(label,value) {return node('div',{},[node('div',{class:'detail-label',text:label}),node('div',{class:'detail-value',text:value})]);}
function empty(text,note='',symbol='grid') {return node('div',{class:'empty'},[icon(symbol),node('strong',{text}),note]);}
function progress(used,quota) {return node('progress',{value:used,max:quota,class:used/quota>.85?'warning':'','aria-label':'Использовано хранилища: '+bytes(used)+' из '+bytes(quota)});}
function notify(text,error=false) {$('toast').textContent=text;$('toast').className='toast'+(error?' error':'');$('toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('toast').hidden=true,5500);}
function showError(id,text) {$(id).textContent=text;$(id).hidden=!text;}
function signedOut() {
  epoch++;me=null;data=null;csrf='';$('workspace').hidden=true;$('loginScreen').hidden=false;
  for(const id of ['overviewCards','statisticsCards','overviewChart','statisticsChart','usersTable','devicesTable','historyTable','recentActivity','activityList','storageSummary','serverDetails','accountDetails','editorBody']) $(id).replaceChildren();
  for(const id of ['myName','myRole','myAvatar','trafficSummary','statisticsDetails','updatedAt'])$(id).textContent='';
  $('passwordForm').reset();$('editorForm').reset();$('editor').close();$('confirmation').close();saveEditor=null;
}
async function api(path,value) {
  let response;
  try {response=await fetch(path,{credentials:'same-origin',cache:'no-store',redirect:'error',method:value===undefined?'GET':'POST',headers:value===undefined?{}:{'Content-Type':'application/json','X-SSH-Hub-CSRF':csrf},body:value===undefined?undefined:JSON.stringify(value)});}
  catch {throw Error('Сервер недоступен. Проверь подключение к сети и VPN.');}
  let result;try{result=await response.json();}catch{throw Error('Сервер вернул некорректный ответ.');}
  if(!response.ok){if(response.status===401&&result.error==='unauthorized')signedOut();throw Error(errors[result.error]||'Не удалось выполнить запрос ('+response.status+').');}
  return result;
}
function route() {
  let name=location.hash.slice(1)||'overview';if(!views[name]||(name==='users'&&me?.role!=='admin'))name='overview';
  for(const item of document.querySelectorAll('.view'))item.hidden=item.id!=='view-'+name;
  for(const item of document.querySelectorAll('nav a')){item.classList.toggle('active',item.dataset.view===name);if(item.dataset.view===name)item.setAttribute('aria-current','page');else item.removeAttribute('aria-current');}
  $('pageTitle').textContent=views[name][0];$('pageDescription').textContent=views[name][1];
}
async function refresh(initial=false) {
  if(refreshing||writing)return;refreshing=true;const version=epoch;$('refresh').disabled=true;$('refresh').classList.add('busy-spin');
  try {
    const identity=await api('/api/v1/me');const next=await api(identity.role==='admin'?'/api/admin/dashboard':'/api/v1/dashboard');
    if(version!==epoch)return;const entering=!me;me=identity;csrf=identity.csrf;data=next;
    $('loginScreen').hidden=true;$('workspace').hidden=false;$('myName').textContent=me.username;$('myRole').textContent=me.role==='admin'?'Администратор':'Пользователь';$('myAvatar').textContent=me.username.slice(0,2).toUpperCase();
    $('pageKicker').textContent=me.role==='admin'?'Панель управления':'Личный кабинет';
    for(const item of document.querySelectorAll('.admin-only'))item.hidden=me.role!=='admin';
    $('usersCount').textContent=data.summary.users;$('serverVersion').textContent=data.version;$('updatedAt').textContent='Обновлено '+date(data.generatedAt,true);
    $('serverState').textContent='Подключено к серверу';document.querySelector('.server-state').classList.remove('offline');showError('pageError','');render();route();if(entering)window.scrollTo(0,0);
  } catch(error) {
    if(me){showError('pageError',error.message);$('serverState').textContent='Нет связи с сервером';document.querySelector('.server-state').classList.add('offline');}
    else if(!initial)showError('loginError',error.message);
  } finally {refreshing=false;$('refresh').disabled=false;$('refresh').classList.remove('busy-spin');}
}
function metrics(id,values) {$(id).replaceChildren(...values.map(([label,value,note,symbol])=>node('div',{class:'metric'},[node('div',{class:'metric-label'},[label,icon(symbol)]),node('div',{class:'metric-value',text:String(value)}),node('div',{class:'metric-note',text:note})])));}
function chart(id,field) {
  const days=[];const byDay=new Map(data.daily.map(item=>[item.day,item]));
  for(let n=29;n>=0;n--){const day=new Date(data.generatedAt*1000-n*86400000).toISOString().slice(0,10);days.push({day,value:byDay.get(day)?.[field]||0});}
  const max=Math.max(1,...days.map(item=>item.value)),svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('class','chart');svg.setAttribute('viewBox','0 0 600 150');svg.setAttribute('preserveAspectRatio','none');svg.setAttribute('role','img');svg.setAttribute('aria-label','Активность за 30 дней: '+number(days.reduce((sum,item)=>sum+item.value,0)));
  for(const y of [3,50,97,147]){const line=document.createElementNS(svg.namespaceURI,'line');for(const [key,val] of Object.entries({x1:0,x2:600,y1:y,y2:y}))line.setAttribute(key,val);svg.append(line);}
  days.forEach((item,index)=>{const rect=document.createElementNS(svg.namespaceURI,'rect'),height=Math.max(3,item.value/max*135);for(const [key,value] of Object.entries({x:index*20+4,y:147-height,width:12,height,rx:3}))rect.setAttribute(key,value);if(!item.value)rect.setAttribute('class','chart-zero');const title=document.createElementNS(svg.namespaceURI,'title');title.textContent=item.day+': '+number(item.value);rect.append(title);svg.append(rect);});
  const format=day=>new Intl.DateTimeFormat('ru-RU',{day:'numeric',month:'short'}).format(new Date(day+'T12:00:00'));
  $(id).replaceChildren(svg,node('div',{class:'chart-labels'},[node('span',{text:format(days[0].day)}),node('span',{text:format(days[14].day)}),node('span',{text:format(days[29].day)})]));
  if(!days.some(item=>item.value))$(id).append(node('div',{class:'chart-empty',text:'Здесь появится активность после синхронизации приложения'}));
}
function footer(id,items) {$(id).replaceChildren(...items.map(([label,value])=>node('span',{},[label,node('strong',{text:value})])));}
function render() {
  const s=data.summary,admin=me.role==='admin';
  metrics('overviewCards',[[admin?'Пользователи':'Мои устройства',number(admin?s.users:s.devices),admin?'Включено: '+number(s.enabledUsers):'С доступом: '+number(s.activeDevices),admin?'users':'device'],['Активные сеансы',number(s.sessions),'Устройств за 5 минут: '+number(s.recentDevices),'device'],['Занято в облаке',bytes(s.bytes),'из '+bytes(s.quotaBytes),'shield'],['Сохранённые версии',number(s.versions),s.lastSync?'Последняя: '+relative(s.lastSync):'Первый снимок ещё не загружен','clock']]);
  chart('overviewChart','pushes');footer('trafficSummary',[['Сохранено снимков',number(s.pushes)],['Получено из облака',bytes(s.downloaded)],['Передано в облако',bytes(s.uploaded)]]);
  $('storageSummary').replaceChildren(node('div',{class:'storage-value',text:bytes(s.bytes)}),node('div',{class:'storage-subtitle',text:'зашифрованных данных из '+bytes(s.quotaBytes)}),progress(s.bytes,s.quotaBytes),node('div',{class:'storage-line'},[node('span',{text:Math.round(s.bytes/s.quotaBytes*100)+'% квоты'}),node('span',{text:'Свободно '+bytes(Math.max(0,s.quotaBytes-s.bytes))})]));
  activity('recentActivity',data.activity.slice(0,5));
  if(admin){const server=data.server;$('serverDetails').replaceChildren(detail('Работает без перезапуска',server.uptimeSeconds<3600?Math.floor(server.uptimeSeconds/60)+' мин':Math.floor(server.uptimeSeconds/3600)+' ч'),detail('Свободно в контейнере',bytes(server.diskFreeBytes)),detail('Последняя резервная копия',server.lastBackup?date(server.lastBackup,true):'Копия ещё не обнаружена'),detail('История снимков','До '+data.historyLimit+' версий'));}
  metrics('statisticsCards',[['Запросы API',number(s.requests),'За последние 30 дней','chart'],['В облако',bytes(s.uploaded),'Объём запросов синхронизации','shield'],['Из облака',bytes(s.downloaded),'Объём ответов синхронизации','device'],['Ошибки обмена',number(s.errors),'Включая конфликты ревизий','clock']]);
  chart('statisticsChart','requests');footer('statisticsDetails',[['Сохранений',number(s.pushes)],['Получений снимков',number(s.pulls)],['Использовано на диске',bytes(s.fileBytes)]]);
  usersTable();devicesTable();historyTable();renderActivity();$('serverAddress').value=location.origin;
  $('accountDetails').replaceChildren(detail('Логин',me.username),detail('Роль',admin?'Администратор':'Пользователь'));
}
function table(id,headers,items,row,key) {
  const host=$(id);host.replaceChildren();if(!items.length){host.append(empty('Ничего не найдено','Попробуй изменить фильтр или вернись позже.'));return;}
  const size=50,page=key?Math.min(pages[key]||0,Math.ceil(items.length/size)-1):0;
  const body=node('tbody'),value=node('table',{'aria-label':headers.join(', ')},[node('thead',{},[node('tr',{},headers.map(label=>node('th',{scope:'col',text:label})))]),body]);
  for(const item of items.slice(page*size,(page+1)*size))body.append(node('tr',{},row(item).map(cell=>node('td',{},[cell]))));host.append(value);
  if(items.length>size&&key){const prev=button('←','page-prev',key),next=button('→','page-next',key);prev.disabled=page===0;next.disabled=(page+1)*size>=items.length;pages[key]=page;host.append(node('div',{class:'pagination'},[number(page*size+1)+'–'+number(Math.min((page+1)*size,items.length))+' из '+number(items.length),node('div',{},[prev,next])]));}
}
function usersTable() {
  if(!data)return;const term=$('userSearch').value.toLowerCase(),filter=$('userFilter').value;
  const items=data.users.filter(item=>item.username.toLowerCase().includes(term)&&(filter==='all'||(filter==='enabled')===Boolean(item.enabled)));
  table('usersTable',['Пользователь','Роль','Статус','Устройства','Хранилище','Активность',''],items,item=>[
    node('div',{class:'name-cell'},[avatar(item.username),node('div',{},[button(item.username,'user-details',item.id,'user-link'),item.id===me.id?node('small',{text:'Это ты'}):null])]),
    badge(item.role==='admin'?'Администратор':'Пользователь',item.role==='admin'?'blue':''),badge(item.enabled?'Включён':'Отключён',item.enabled?'good':''),number(item.activeDevices),
    node('div',{class:'storage-mini'},[bytes(item.bytes),progress(item.bytes,item.quotaBytes)]),node('span',{text:relative(item.lastSeen),title:date(item.lastSeen)}),node('div',{class:'table-actions'},[button('Управлять','user-details',item.id)])
  ],'users');
}
function devicesTable() {
  if(!data)return;const term=$('deviceSearch').value.toLowerCase(),filter=$('deviceFilter').value;$('deviceTotal').textContent=number(data.devices.length);
  const items=data.devices.filter(item=>[item.name,item.username,item.ip].some(value=>value.toLowerCase().includes(term))&&(filter==='all'||(filter==='active')===Boolean(item.sessions)));
  table('devicesTable',['Устройство',...(me.role==='admin'?['Пользователь']:[]),'Доступ','Последняя активность','IP-адрес',''],items,item=>[
    node('div',{class:'name-cell'},[node('span',{class:'device-icon'},[icon(item.kind==='web'?'grid':'device')]),node('div',{},[node('strong',{text:item.name}),node('small',{text:[item.platform|| (item.kind==='web'?'Веб-панель':'Приложение'),item.version,item.current?'Этот сеанс':''].filter(Boolean).join(' · ')})])]),
    ...(me.role==='admin'?[item.username]:[]),badge(item.sessions?'Разрешён':'Нет сеансов',item.sessions?'good':''),node('span',{text:relative(item.lastSeen),title:date(item.lastSeen)}),item.ip||'—',
    node('div',{class:'table-actions'},[button('Название','device-rename',item.id),...(item.sessions?[button('Отозвать','device-revoke',item.id,'danger')]:[])])
  ],'devices');
}
function historyTable() {
  if(me.role==='admin'){$('historyTitle').textContent='Хранилища пользователей';table('historyTable',['Пользователь','Занято','Квота','Версий','Текущая ревизия','Последний снимок'],data.users,item=>[item.username,bytes(item.bytes),bytes(item.quotaBytes),number(item.versions),number(item.revision),date(item.lastSync,true)],'storage');}
  else{$('historyTitle').textContent='История снимков';table('historyTable',['Ревизия','Создана','Размер снимка'],data.history,item=>['№ '+item.revision,date(item.created),bytes(item.bytes)]);}
}
const eventNames={login:'Вход в облако',logout:'Выход из облака',user_created:'Создана учётная запись',user_enabled:'Доступ включён',user_disabled:'Доступ отключён',password_changed:'Изменён пароль учётной записи',password_reset:'Сброшен пароль учётной записи',role_admin:'Назначен администратор',role_user:'Назначена роль пользователя',sessions_revoked:'Завершены все сеансы',device_revoked:'Отозван доступ устройства',device_renamed:'Изменено название устройства',sync_push:'Сохранён снимок',sync_pull:'Получен снимок',sync_error:'Ошибка синхронизации'};
function eventGroup(action){return action.startsWith('sync_')?'sync':action.startsWith('user_')||action.startsWith('role_')||action.startsWith('password_')?'users':'access';}
function activity(id,items){$(id).replaceChildren(...items.map(item=>node('div',{class:'event'},[node('span',{class:'event-icon'},[icon(item.action.startsWith('sync_')?'refresh':eventGroup(item.action)==='users'?'users':'shield')]),node('div',{},[node('div',{class:'event-title',text:eventNames[item.action]||'Событие'}),node('div',{class:'event-description',text:[item.username,item.device,item.revision?'Ревизия '+item.revision:'',item.actor!==item.username?'Автор: '+item.actor:''].filter(Boolean).join(' · ')})]),node('time',{datetime:new Date(item.created*1000).toISOString(),text:date(item.created,true),title:date(item.created)})])));if(!items.length)$(id).append(empty('Пока нет событий','Новые входы и синхронизации появятся здесь.','clock'));}
function renderActivity(){if(!data)return;const filter=$('activityFilter').value;activity('activityList',data.activity.filter(item=>filter==='all'||eventGroup(item.action)===filter));}
function ask(title,text,action='Подтвердить'){
  return new Promise(resolve=>{$('confirmationTitle').textContent=title;$('confirmationText').textContent=text;$('acceptConfirmation').textContent=action;let accepted=false;
    $('acceptConfirmation').onclick=()=>{accepted=true;$('confirmation').close();};$('cancelConfirmation').onclick=()=>$('confirmation').close();$('confirmation').onclose=()=>resolve(accepted);$('confirmation').showModal();});
}
function field(id,label,type='text',value='') {const input=node('input',{id,type,required:true,maxlength:type==='password'?1024:80,autocomplete:type==='password'?'new-password':'off'});input.value=value;if(type==='password')input.minLength=12;return node('div',{},[node('label',{for:id,text:label}),input]);}
function editor(title,kicker,body,save=null,label='Сохранить'){$('editorTitle').textContent=title;$('editorKicker').textContent=kicker;$('editorBody').replaceChildren(...body);$('saveEditor').hidden=!save;$('saveEditor').textContent=label;saveEditor=save;showError('editorError','');$('editor').showModal();}
function newUser(){editor('Новый пользователь','Доступ к облаку',[field('editUsername','Логин'),field('editPassword','Начальный пароль · от 12 символов','password'),field('editConfirmation','Повтори пароль','password'),node('p',{class:'muted',text:'Новая учётная запись получит роль пользователя и отдельное хранилище. Администратором её можно назначить позже.'})],async()=>{if($('editPassword').value!==$('editConfirmation').value)throw Error('Пароли не совпадают.');await api('/api/admin/users',{username:$('editUsername').value,password:$('editPassword').value});return 'Пользователь создан. Передай пароль безопасным способом.';},'Создать пользователя');}
function userDetails(user){
  const actions=[button('Завершить сеансы','user-revoke',user.id)];
  if(user.id!==me.id)actions.push(button('Сбросить пароль','user-password',user.id),button(user.enabled?'Отключить':'Включить','user-toggle',user.id,user.enabled?'danger':'secondary'),button(user.role==='admin'?'Снять права администратора':'Назначить администратором','user-role',user.id));
  editor(user.username,'Управление пользователем',[node('div',{class:'detail-grid two'},[detail('Статус',user.enabled?'Включён':'Отключён'),detail('Роль',user.role==='admin'?'Администратор':'Пользователь'),detail('Создан',date(user.created,true)),detail('Активные сеансы',number(user.sessions)),detail('Занято в облаке',bytes(user.bytes)),detail('Последний снимок',date(user.lastSync,true))]),node('div',{class:'user-details-actions'},actions)]);
}
async function mutation(path,value,message){if(writing)return;writing=true;try{await api(path,value);epoch++;notify(message);}catch(error){notify(error.message,true);}finally{writing=false;await refresh();}}
async function action(name,id){
  if(name.startsWith('page-')){pages[id]=Math.max(0,pages[id]+(name==='page-next'?1:-1));if(id==='users')usersTable();else if(id==='storage')historyTable();else devicesTable();return;}
  const user=data?.users.find(item=>item.id===id),device=data?.devices.find(item=>item.id===id);
  if(name==='user-details'&&user){userDetails(user);return;}
  if(name==='device-rename'&&device){editor('Название устройства',device.username,[field('editDeviceName','Название','text',device.name)],async()=>{await api('/api/v1/devices/rename',{id,name:$('editDeviceName').value});return 'Название обновлено.';});return;}
  if(name==='user-password'&&user){$('editor').close();editor('Сбросить пароль',user.username,[field('editPassword','Новый пароль · от 12 символов','password'),field('editConfirmation','Повтори пароль','password'),node('p',{class:'muted',text:'Все сеансы пользователя завершатся. Мастер-пароль и зашифрованная база останутся прежними.'})],async()=>{if($('editPassword').value!==$('editConfirmation').value)throw Error('Пароли не совпадают.');await api('/api/admin/users/password',{id,password:$('editPassword').value});return 'Пароль изменён. Все сеансы пользователя завершены.';},'Сбросить пароль');return;}
  $('editor').close();
  if(name==='device-revoke'&&device&&await ask('Отозвать доступ?',device.name+' · '+device.username+'. Для синхронизации потребуется новый вход.'+(device.current?' Этот сеанс браузера также завершится.':''),'Отозвать доступ'))await mutation('/api/v1/devices/revoke',{id},'Доступ устройства отозван.');
  if(name==='user-toggle'&&user&&await ask(user.enabled?'Отключить пользователя?':'Включить пользователя?',user.username+(user.enabled?': все сеансы завершатся. Зашифрованные данные сохранятся.':': снова сможет войти в облако.'),user.enabled?'Отключить':'Включить'))await mutation('/api/admin/users/enable',{id,enabled:!user.enabled},'Статус пользователя обновлён.');
  if(name==='user-role'&&user&&await ask('Изменить роль?',user.username+(user.role==='admin'?' потеряет права администратора.':' сможет управлять учётными записями и доступом устройств.')+' Все его сеансы завершатся.','Изменить роль'))await mutation('/api/admin/users/role',{id,role:user.role==='admin'?'user':'admin'},'Роль пользователя изменена.');
  if(name==='user-revoke'&&user&&await ask('Завершить все сеансы?',user.username+': приложения и браузеры должны будут войти заново. Локальные данные сохранятся.','Завершить сеансы'))await mutation('/api/admin/users/revoke',{id},'Сеансы завершены.');
}
document.body.addEventListener('click',event=>{const target=event.target.closest('button[data-action]');if(target&&!writing)action(target.dataset.action,target.dataset.id).catch(error=>notify(error.message,true));});
$('editorForm').onsubmit=async event=>{event.preventDefault();if(!saveEditor||writing)return;writing=true;const callback=saveEditor,form=$('editorForm');for(const item of form.elements)item.disabled=true;
  try{const message=await callback();$('editor').close();epoch++;notify(message||'Сохранено.');}catch(error){showError('editorError',error.message);for(const item of form.querySelectorAll('input[type=password]'))item.value='';}
  finally{for(const item of form.elements)item.disabled=false;writing=false;await refresh();}};
for(const id of ['closeEditor','cancelEditor'])$(id).onclick=()=>$('editor').close();
$('editor').addEventListener('close',()=>{for(const input of $('editorBody').querySelectorAll('input[type=password]'))input.value='';});
$('loginForm').onsubmit=async event=>{event.preventDefault();if(writing)return;writing=true;showError('loginError','');const submit=event.submitter;submit.disabled=true;
  try{const ua=navigator.userAgent,platform=/Android/.test(ua)?'Android':/iPhone|iPad/.test(ua)?'iOS':/Mac/.test(ua)?'macOS':/Windows/.test(ua)?'Windows':'Linux';const browser=/Edg\//.test(ua)?'Edge':/Firefox\//.test(ua)?'Firefox':/Chrome\//.test(ua)?'Chrome':'Safari';let deviceId;try{deviceId=localStorage.getItem('sshHubDeviceId');if(!deviceId){deviceId=crypto.randomUUID();localStorage.setItem('sshHubDeviceId',deviceId);}}catch{}
    await api('/api/v1/login',{username:$('username').value,password:$('password').value,device:browser+' · '+platform,deviceId,platform,clientVersion:'Web 2.0'});epoch++;location.hash='overview';
  }catch(error){showError('loginError',error.message);}finally{$('password').value='';submit.disabled=false;writing=false;await refresh(true);}};
$('logout').onclick=async()=>{try{await api('/api/v1/logout',{});signedOut();notify('Ты вышел из облака.');}catch(error){notify(error.message,true);}};
$('accountLogout').onclick=()=>$('logout').click();
$('passwordForm').onsubmit=async event=>{event.preventDefault();if($('accountPassword').value!==$('accountConfirmation').value){notify('Пароли не совпадают.',true);return;}if(!await ask('Изменить пароль?', 'Все приложения и браузеры, включая этот сеанс, должны будут войти заново. Мастер-пароль базы останется прежним.','Изменить пароль'))return;
  await mutation('/api/v1/password',{currentPassword:$('currentPassword').value,password:$('accountPassword').value},'Пароль изменён. Войди с новым паролем.');$('passwordForm').reset();};
$('revokeOwnSessions').onclick=async()=>{if(await ask('Выйти на всех устройствах?','Этот браузер тоже завершит сеанс. Локальные данные в приложениях сохранятся.','Завершить все сеансы'))await mutation('/api/v1/sessions/revoke',{},'Все сеансы завершены.');};
$('copyAddress').onclick=async()=>{try{await navigator.clipboard.writeText(location.origin);notify('Адрес скопирован.');}catch{notify('Выдели и скопируй адрес из поля.',true);}};
$('newUser').onclick=newUser;$('refresh').onclick=()=>refresh();
for(const id of ['userSearch','userFilter'])$(id).addEventListener('input',()=>{pages.users=0;usersTable();});
for(const id of ['deviceSearch','deviceFilter'])$(id).addEventListener('input',()=>{pages.devices=0;devicesTable();});
$('activityFilter').onchange=renderActivity;window.addEventListener('hashchange',()=>{route();window.scrollTo(0,0);});
setInterval(()=>{if(me&&!document.hidden&&!$('editor').open&&!$('confirmation').open)refresh();},60000);
route();refresh(true);
