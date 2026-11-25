import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, KeyboardAvoidMode, curves } from '@kit.ArkUI';
import { QuadrantMeta, QUADRANTS, TaskItem, Q1, Q2 } from '../model/TaskItem';
import { Account } from '../model/Account';
import { dailyQuote, QuoteItem } from '../model/Quote';
import {
  AppSettings, COLOR_MODE_OPTIONS, FONT_FOLLOW, FONT_MODE_OPTIONS, fontRatioOf, MODE_DARK, MODE_LIGHT, MODE_SYSTEM,
  SettingOption, SORT_OPTIONS, WIDGET_LINE_OPTIONS
} from '../model/AppSettings';
import { TaskRepository } from '../data/TaskRepository';
import { AccountStore } from '../data/AccountStore';
import { SettingsStore } from '../data/SettingsStore';
import { PrefStore } from '../data/PrefStore';
import { WidgetBridge } from '../data/WidgetBridge';
import { HuaweiAuthService, HuaweiIdProfile } from '../data/HuaweiAuthService';
import { BackupService, BackupResult } from '../data/BackupService';
import { CalSyncService, CalSyncConfig } from '../data/CalSyncService';
import { LocalCalService, LocalCalResult } from '../data/LocalCalService';
import { FontScaleService } from '../data/FontScaleService';
import { DateUtil } from '../common/DateUtil';

const DOMAIN: number = 0x0000;
const TAG: string = 'QuadrantTodo';
const APP_VERSION: string = '1.1.7';
/** 协议版本：内容有实质变更时 +1，用户需重新确认 */
const AGREEMENT_VERSION: number = 1;
const KEY_AGREE_ACCEPTED: string = 'agree_accepted';
const KEY_AGREE_VERSION: string = 'agree_version';


/**
 * 输入框独立成组件。
 * 之前输入框直接写在页面里，每敲一个字都会把整页（四个格子 + 全部任务卡）重绘一次，
 * 中文输入法组词时尤其卡。抽成子组件后，打字只重绘这个输入框自己。
 */
@Component
struct QuickInput {
  @Link text: string;
  @Prop placeholder: string = '';
  @Prop boxHeight: number = 32;
  @Prop fontSize: number = 12;
  @Prop boxBg: ResourceColor = Color.Transparent;
  @Prop topMargin: number = 0;
  onCommit: () => void = () => {
  };

  build() {
    TextInput({ placeholder: this.placeholder, text: this.text })
      .placeholderColor($r('app.color.muted'))
      .placeholderFont({ size: this.fontSize })
      .fontSize(this.fontSize)
      .fontColor($r('app.color.fg'))
      .height(this.boxHeight)
      .width('100%')
      .borderRadius(10)
      .padding({ left: 8, right: 8 })
      .margin({ top: this.topMargin })
      .backgroundColor(this.boxBg)
      .onChange((value: string) => {
        this.text = value;
      })
      .onSubmit(() => {
        this.onCommit();
      })
  }
}


@Entry
@Component
struct Index {
  /** 未完成任务全集，四个格子按象限过滤渲染 */
  @State tasks: TaskItem[] = [];
  /** 全部任务（含已完成），归类页按周统计与已完成弹窗共用此源 */
  @State allTasks: TaskItem[] = [];
  @State ready: boolean = false;
  @State completedToday: number = 0;

  /** 账号与设置（账号仅作数据维度，不再提供管理界面） */
  @State account: Account = new Account();
  @State settings: AppSettings = new AppSettings();
  @State showSettings: boolean = false;

  /** 用户协议：false 时全屏展示协议页，同意前无法使用应用 */
  @State agreed: boolean = true;

  /** 设置页「关于」是否展开，默认折叠 */
  @State aboutExpanded: boolean = false;

  /** 编辑面板 */
  @State showEditor: boolean = false;
  @State editingId: number = 0;
  @State draftTitle: string = '';
  @State draftQuadrant: number = Q1;
  @State draftDue: number = 0;
  @State draftImportant: boolean = false;
  @State draftDate: Date = new Date();
  @State showCalendar: boolean = false;
  /** B 方案编辑屏：当前状态（待办中 / 已完成） */
  @State draftDone: boolean = false;
  @State editingDone: boolean = false;

  /** 归类说明面板 */
  @State showRuler: boolean = false;

  /** 已完成面板 */
  @State showDone: boolean = false;
  @State doneTasks: TaskItem[] = [];

  /** 底部导航当前页签：0=时间轴 1=归类（本周） 2=设置 */
  @State navTab: number = 0;
  /** 导航项点击弹跳：记录正在弹跳的 tab（-1=无），驱动 scale 动画 */
  @State navBounceTab: number = -1;

  /** 时间轴主屏：象限筛选（0=全部）与统一输入行 */
  @State timelineFilter: number = 0;
  @State timelineInput: string = '';

  /** 四个格子的快速输入框内容（编辑面板与兼容旧数据保留） */
  @State inputQ1: string = '';
  @State inputQ2: string = '';
  @State inputQ3: string = '';
  @State inputQ4: string = '';


  /** 华为账号与云备份 */
  @State hwNickName: string = '';
  @State hwAvatar: string = '';
  @State hwOpenId: string = '';
  @State hwBusy: boolean = false;
  @State hwError: string = '';
  @State autoBackup: boolean = true;
  @State lastBackupText: string = '';
  @State backupBusy: boolean = false;

  /** 日历订阅（Gitee 托管 ICS） */
  @State calEnabled: boolean = false;
  @State calOwner: string = '';
  @State calRepo: string = '';
  @State calToken: string = '';
  @State calUrl: string = '';
  @State calLastSync: string = '';
  @State calBusy: boolean = false;
  private calSyncGuard: number = 0;

  /** 本机日历（HarmonyOS Calendar Kit） */
  @State localCalEnabled: boolean = false;
  @State localCalLast: string = '';
  @State localCalBusy: boolean = false;
  private localCalGuard: number = 0;

  /** 沉浸式安全区避让（vp） */
  @State topInset: number = 0;
  @State bottomInset: number = 0;
  /** 软键盘是否弹起：弹起时归零底部留白，让输入行贴住键盘上沿 */
  @State keyboardVisible: boolean = false;

  /** 系统当前字体缩放比，仅用于设置页展示 */
  @State systemFontScale: number = 1;

  private ctx: common.UIAbilityContext | undefined = undefined;

  aboutToAppear(): void {
    // 官方推荐：底部操作栏被键盘遮挡时用压缩模式，内容区高度减去键盘高度
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.boot();
  }

  /** 协议未确认前拦截返回键，只能选择同意或退出 */
  onBackPress(): boolean {
    return !this.agreed;
  }

  /* ==================== 数据 ==================== */

  private async boot(): Promise<void> {
    try {
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.ctx = context;
      await AccountStore.init(context);
      await SettingsStore.init(context);
      this.settings = SettingsStore.current();
      this.account = AccountStore.active();
      this.systemFontScale = FontScaleService.systemScale(context);
      this.agreed = PrefStore.getBool(KEY_AGREE_ACCEPTED, false)
        && PrefStore.getNumber(KEY_AGREE_VERSION, 0) >= AGREEMENT_VERSION;

      const repo: TaskRepository = TaskRepository.getInstance();
      await repo.init(context);
      repo.useAccount(this.account.id);
      this.applyColorMode(this.settings.colorMode);
      this.refreshHuaweiState();
      this.autoBackup = BackupService.autoEnabled();
      this.refreshBackupState();
      await CalSyncService.init(context);
      this.refreshCalState();
      await LocalCalService.init(context);
      this.refreshLocalCalState();
      this.computeInsets();
      await this.reload();
      this.ready = true;
      if (this.autoBackup && HuaweiAuthService.loggedIn()) {
        this.runAutoBackup();
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'boot failed: %{public}s', (err as Error).message);
      this.toast('初始化失败：' + (err as Error).message);
    }
  }

  /** 读取状态栏/导航条高度，内容按安全区避让，背景延伸到状态栏 */
  private async computeInsets(): Promise<void> {
    if (this.ctx === undefined) {
      return;
    }
    try {
      const win: window.Window = await window.getLastWindow(this.ctx);
      win.on('keyboardHeightChange', (height: number) => {
        this.keyboardVisible = height > 0;
      });
      const sysArea: window.AvoidArea =
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const navArea: window.AvoidArea =
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      this.topInset = this.getUIContext().px2vp(sysArea.topRect.height);
      this.bottomInset = this.getUIContext().px2vp(navArea.bottomRect.height);
    } catch (err) {
      this.topInset = 0;
      this.bottomInset = 0;
    }
  }

  private async reload(): Promise<void> {
    try {
      this.tasks = await TaskRepository.getInstance().listActive(this.settings.sortMode);
      this.allTasks = await TaskRepository.getInstance().listAll();
      this.completedToday = await TaskRepository.getInstance().countCompletedSince(DateUtil.todayStart());
      if (this.showDone) {
        this.loadDone();
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'reload failed: %{public}s', (err as Error).message);
    }
  }

  /**
   * 任何写操作之后：只等本地库刷新（毫秒级）。
   * 卡片推送、云备份、日历同步全部延后到后台执行，
   * 否则「保存」要等好几秒（网络往返 + 卡片 IPC + 云端上传）才会有反应。
   */
  private async afterChange(): Promise<void> {
    await this.reload();
    // 卡片立即推送（纯本地构建，毫秒级）；网络类工作走防抖
    WidgetBridge.refreshAll(this.ctx).catch(() => {
    });
    this.scheduleSideWork();
  }

  private sideTimer: number = -1;

  /** 连续改动作业时只跑最后一次，避免每次都推卡片/备份 */
  private scheduleSideWork(): void {
    if (this.sideTimer !== -1) {
      clearTimeout(this.sideTimer);
    }
    this.sideTimer = setTimeout(() => {
      this.sideTimer = -1;
      this.runSideWork();
    }, 400);
  }

  private fmtCalTime(ms: number): string {
    const d: Date = new Date(ms);
    const p = (n: number): string => n.toString().padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  private refreshCalState(): void {
    const cfg: CalSyncConfig = CalSyncService.getConfig();
    this.calEnabled = cfg.enabled;
    this.calOwner = cfg.owner;
    this.calRepo = cfg.repo;
    this.calToken = cfg.token;
    this.calUrl = CalSyncService.subscriptionUrl(cfg);
    this.calLastSync = cfg.lastSync > 0 ? this.fmtCalTime(cfg.lastSync) : '';
  }

  private async calPersist(enabled: boolean): Promise<void> {
    const cfg: CalSyncConfig = CalSyncService.getConfig();
    cfg.enabled = enabled;
    cfg.owner = this.calOwner.trim();
    cfg.repo = this.calRepo.trim();
    cfg.token = this.calToken.trim();
    if (cfg.pathId.length === 0) {
      cfg.pathId = CalSyncService.newCandidatePathId();
    }
    await CalSyncService.saveConfig(cfg);
    this.refreshCalState();
  }

  private async calToggle(on: boolean): Promise<void> {
    await this.calPersist(on);
    if (on && CalSyncService.ready(CalSyncService.getConfig())) {
      this.calSyncNow();
    }
  }

  private async calSave(): Promise<void> {
    if (this.calOwner.trim().length === 0 || this.calRepo.trim().length === 0 ||
      this.calToken.trim().length === 0) {
      this.toast('请填写 Gitee 用户名、仓库名和私人令牌');
      return;
    }
    await this.calPersist(this.calEnabled);
    this.toast('已保存');
    if (CalSyncService.ready(CalSyncService.getConfig())) {
      this.calSyncNow();
    }
  }

  private calCopyUrl(): void {
    if (this.calUrl.length === 0) {
      this.toast('尚未生成订阅链接');
      return;
    }
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.calUrl);
    pasteboard.getSystemPasteboard().setData(data);
    this.toast('订阅链接已复制，去 iPhone 日历 → 账户 → 添加订阅日历粘贴');
  }

  private async calSyncNow(): Promise<void> {
    if (this.calBusy) {
      return;
    }
    this.calBusy = true;
    try {
      await CalSyncService.syncNow();
      this.refreshCalState();
      this.toast('日历已同步到 Gitee');
    } catch (err) {
      this.toast((err as Error).message);
    } finally {
      this.calBusy = false;
    }
  }

  /** 自动同步：60s 节流，失败静默 */
  private calAutoSync(): void {
    if (!CalSyncService.ready(CalSyncService.getConfig()) || this.calBusy) {
      return;
    }
    const now: number = Date.now();
    if (now - this.calSyncGuard < 60000) {
      return;
    }
    this.calSyncGuard = now;
    CalSyncService.syncNow().catch(() => {
    });
  }

  /* ==================== 本机日历（系统日历） ==================== */

  private refreshLocalCalState(): void {
    this.localCalEnabled = LocalCalService.isEnabled();
    const last: number = LocalCalService.getLastSync();
    this.localCalLast = last > 0 ? this.fmtCalTime(last) : '';
  }

  /** 同步到系统日历：先要权限，再按「带截止日 + 未完成」对账 */
  private async localCalSync(showToast: boolean): Promise<void> {
    if (this.localCalBusy || this.ctx === undefined) {
      return;
    }
    this.localCalBusy = true;
    try {
      const granted: boolean = await LocalCalService.ensurePermission(this.ctx);
      if (!granted) {
        if (showToast) {
          this.toast('未获得日历权限，请在系统设置中允许「象限待办」访问日历');
        }
        return;
      }
      const tasks: TaskItem[] = await TaskRepository.getInstance().listAll();
      const result: LocalCalResult = await LocalCalService.syncNow(this.ctx, tasks);
      this.refreshLocalCalState();
      if (showToast) {
        this.toast(`已同步到系统日历：${result.summary()}`);
      }
    } catch (err) {
      if (showToast) {
        this.toast((err as Error).message);
      }
    } finally {
      this.localCalBusy = false;
    }
  }

  private async localCalToggle(on: boolean): Promise<void> {
    if (on) {
      const granted: boolean = this.ctx === undefined ? false :
        await LocalCalService.ensurePermission(this.ctx);
      if (!granted) {
        this.toast('需要日历权限才能同步，请在系统设置中允许「象限待办」访问日历');
        this.localCalEnabled = false;
        return;
      }
      await LocalCalService.setEnabled(true);
      this.localCalEnabled = true;
      await this.localCalSync(true);
      return;
    }
    await LocalCalService.setEnabled(false);
    this.refreshLocalCalState();
    this.toast('已停止自动同步，已写入的事件保留在本机日历中');
  }

  private confirmLocalCalClear(): void {
    this.getUIContext().showAlertDialog({
      title: '清除本机日历事件',
      message: '将删除「象限待办」写入系统日历的全部事件（不影响你手动创建的其他日程），是否继续？',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清除',
        fontColor: $r('app.color.danger'),
        action: () => {
          this.doLocalCalClear();
        }
      }
    });
  }

  private async doLocalCalClear(): Promise<void> {
    if (this.ctx === undefined) {
      return;
    }
    try {
      const removed: number = await LocalCalService.clearAll(this.ctx);
      this.localCalLast = '';
      this.toast(`已清除 ${removed} 条日历事件`);
    } catch (err) {
      this.toast('清除失败：' + (err as Error).message);
    }
  }

  /** 后台自动同步：仅开关打开时执行，60s 节流，失败静默（不打扰用户） */
  private localCalAutoSync(): void {
    if (!this.localCalEnabled || this.localCalBusy || this.ctx === undefined) {
      return;
    }
    const now: number = Date.now();
    if (now - this.localCalGuard < 60000) {
      return;
    }
    this.localCalGuard = now;
    this.localCalSync(false);
  }

  private async runSideWork(): Promise<void> {
    if (this.autoBackup && this.ctx !== undefined) {
      BackupService.autoBackup(this.ctx);
    }
    this.calAutoSync();
    this.localCalAutoSync();
  }

  /** 已完成列表与归类页共用 allTasks 数据源，按完成时间倒序取前 50 条 */
  private loadDone(): void {
    const done: TaskItem[] = [];
    for (let i = 0; i < this.allTasks.length; i++) {
      if (this.allTasks[i].completed) {
        done.push(this.allTasks[i]);
      }
    }
    done.sort((a: TaskItem, b: TaskItem) => b.updatedAt - a.updatedAt);
    this.doneTasks = done.slice(0, 50);
  }

  private openDone(): void {
    this.showDone = true;
    this.loadDone();
  }

  private async restoreTask(item: TaskItem): Promise<void> {
    try {
      await TaskRepository.getInstance().setCompleted(item.id, false);
      await this.afterChange();
    } catch (err) {
      this.toast('恢复失败：' + (err as Error).message);
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'toast failed: %{public}s', (err as Error).message);
    }
  }

  private tasksOf(quadrant: number): TaskItem[] {
    const result: TaskItem[] = [];
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].quadrant === quadrant) {
        result.push(this.tasks[i]);
      }
    }
    return result;
  }

  /* ==================== 时间轴主屏 ==================== */

  /** 距今天的天数：负数=逾期，0=今天，正数=未来；未排期返回超大值排末尾 */
  private dueDays(dueAt: number): number {
    if (dueAt <= 0) {
      return 9999;
    }
    return Math.round((DateUtil.startOfDay(dueAt) - DateUtil.todayStart()) / DateUtil.DAY_MS);
  }

  /** 中文大写月份：壹月~拾贰月；未排期返回空串 */
  private monthCN(dueAt: number): string {
    if (dueAt <= 0) {
      return '';
    }
    const m: number = new Date(dueAt).getMonth() + 1;
    if (m < 1 || m > 12) {
      return '';
    }
    const CN: string[] = ['壹', '贰', '叁', '肆', '伍', '陆', '柒', '捌', '玖', '拾', '拾壹', '拾贰'];
    return CN[m - 1] + '月';
  }

  /** 胶囊长度（vp）：越迫近越长，未排期最短。与原型 DUE_LEN 同序。 */
  private capsuleLen(dueAt: number): number {
    const d: number = this.dueDays(dueAt);
    // 刻度列 28→44vp 容纳中文大写月份，胶囊梯度仅收紧 8vp：
    // 最大「刻度 44 + 胶囊 282」= 326vp < 内容区 328vp。
    // 最短档 182vp 仍留标题列约 88vp，不会压成竖排。
    if (d < 0) {
      return 282;
    }
    if (d === 0) {
      return 256;
    }
    if (d === 1) {
      return 230;
    }
    if (d <= 3) {
      return 204;
    }
    return 182;
  }

  /** 本周一 00:00（周一为第一天） */
  private weekMonday(): number {
    const now: Date = new Date();
    const dow: number = now.getDay(); // 0=周日
    const back: number = dow === 0 ? 6 : dow - 1;
    return DateUtil.dayOffset(-back);
  }

  /** 本周第 i 天（0=周一）的 00:00 时间戳 */
  private weekDay(i: number): number {
    return this.weekMonday() + i * DateUtil.DAY_MS;
  }

  /** 本周某天的任务数（含待办与已完成，按 dueAt 落在当天统计） */
  private weekDayCount(dayStart: number): number {
    let n: number = 0;
    for (let i = 0; i < this.allTasks.length; i++) {
      const t: TaskItem = this.allTasks[i];
      if (t.dueAt > 0 && DateUtil.startOfDay(t.dueAt) === dayStart) {
        n++;
      }
    }
    return n;
  }

  /** 本周任务列表：含待办与已完成，dueAt 落在本周内、按象限筛选后按截止日排序 */
  private weekTasks(): TaskItem[] {
    const result: TaskItem[] = [];
    const start: number = this.weekMonday();
    const end: number = start + 7 * DateUtil.DAY_MS;
    for (let i = 0; i < this.allTasks.length; i++) {
      const t: TaskItem = this.allTasks[i];
      if (t.dueAt <= 0 || t.dueAt < start || t.dueAt >= end) {
        continue;
      }
      if (this.timelineFilter !== 0 && t.quadrant !== this.timelineFilter) {
        continue;
      }
      result.push(t);
    }
    result.sort((a: TaskItem, b: TaskItem) => a.dueAt - b.dueAt);
    return result;
  }

  /** 本周待办总数（用于柱状图峰值归一） */
  private weekTotal(): number {
    let n: number = 0;
    for (let i = 0; i < 7; i++) {
      n += this.weekDayCount(this.weekDay(i));
    }
    return n;
  }

  /** 时间轴数据：未完成任务，先按象限筛选，再按截止日由近到远排序 */
  private timelineTasks(): TaskItem[] {
    const result: TaskItem[] = [];
    for (let i = 0; i < this.tasks.length; i++) {
      const item: TaskItem = this.tasks[i];
      if (item.completed) {
        continue;
      }
      if (this.timelineFilter !== 0 && item.quadrant !== this.timelineFilter) {
        continue;
      }
      result.push(item);
    }
    result.sort((a: TaskItem, b: TaskItem) => {
      const da: number = this.dueDays(a.dueAt);
      const db: number = this.dueDays(b.dueAt);
      if (da !== db) {
        return da - db;
      }
      return b.updatedAt - a.updatedAt;
    });
    return result;
  }

  /** B 方案编辑屏象限按钮标签：Q1 / Q2 / Q3 / Q4 */
  private quadrantTag(quadrant: number): string {
    return 'Q' + quadrant;
  }

  /** B 方案截止日「周五」：取本周五（含今天为周五时即今天） */
  private fridayDue(): number {
    const day: number = new Date().getDay();
    const delta: number = (5 - day + 7) % 7;
    return DateUtil.dayOffset(delta);
  }

  /** 四象限色点资源 */
  private quadrantDot(quadrant: number): Resource {
    if (quadrant === 1) {
      return $r('app.color.q1_dot');
    }
    if (quadrant === 2) {
      return $r('app.color.q2_dot');
    }
    if (quadrant === 3) {
      return $r('app.color.q3_dot');
    }
    return $r('app.color.q4_dot');
  }

  /** 四象限短名（底部归类键用，避免长名在窄键中折行） */
  private quadrantShort(quadrant: number): string {
    if (quadrant === 1) {
      return '重要紧急';
    }
    if (quadrant === 2) {
      return '重要不急';
    }
    if (quadrant === 3) {
      return '次要紧急';
    }
    return '次要不急';
  }

  /**
   * C 式输入行：有字点象限键即归入该象限；无字点键只看该象限（再点取消）。
   * 回车走 addTask 到当前筛选象限，未筛选时默认 Q2。
   */
  private async addToQuadrant(quadrant: number): Promise<void> {
    const title: string = this.timelineInput.trim();
    if (title.length > 0) {
      try {
        await TaskRepository.getInstance().insert(title, quadrant, 0, false);
        this.timelineInput = '';
        await this.afterChange();
        this.toast('已归入「' + this.quadrantShort(quadrant) + '」');
      } catch (err) {
        this.toast('添加失败：' + (err as Error).message);
      }
      return;
    }
    this.timelineFilter = this.timelineFilter === quadrant ? 0 : quadrant;
    this.toast(this.timelineFilter === 0 ? '显示全部象限' : '只看「' + this.quadrantShort(quadrant) + '」');
  }

  private async commitTimelineInput(): Promise<void> {
    const target: number = this.timelineFilter !== 0 ? this.timelineFilter : 2;
    await this.addToQuadrant(target);
  }

  private inputOf(quadrant: number): string {
    if (quadrant === 1) {
      return this.inputQ1;
    }
    if (quadrant === 2) {
      return this.inputQ2;
    }
    if (quadrant === 3) {
      return this.inputQ3;
    }
    return this.inputQ4;
  }

  private setInput(quadrant: number, value: string): void {
    if (quadrant === 1) {
      this.inputQ1 = value;
    } else if (quadrant === 2) {
      this.inputQ2 = value;
    } else if (quadrant === 3) {
      this.inputQ3 = value;
    } else {
      this.inputQ4 = value;
    }
  }

  private quadBg(quadrant: number): Resource {
    if (quadrant === 1) {
      return $r('app.color.q1_bg');
    }
    if (quadrant === 2) {
      return $r('app.color.q2_bg');
    }
    if (quadrant === 3) {
      return $r('app.color.q3_bg');
    }
    return $r('app.color.q4_bg');
  }

  private quadrantName(quadrant: number): string {
    for (let i = 0; i < QUADRANTS.length; i++) {
      if (QUADRANTS[i].key === quadrant) {
        return QUADRANTS[i].name;
      }
    }
    return '';
  }

  /** 每日一言：与桌面卡片共用同一名言库，按当天日期轮换 */
  private quoteLine(): string {
    const q: QuoteItem = dailyQuote();
    return `${q.text} —— ${q.author}`;
  }

  /* ==================== 设置 ==================== */

  private applyColorMode(mode: number): void {
    if (this.ctx === undefined) {
      return;
    }
    let target: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (mode === MODE_DARK) {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else if (mode === MODE_LIGHT) {
      target = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    try {
      this.ctx.getApplicationContext().setColorMode(target);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'setColorMode failed: %{public}s', (err as Error).message);
    }
  }

  private async saveSettings(next: AppSettings, appearanceChanged: boolean): Promise<void> {
    const previous: AppSettings = this.settings;
    this.settings = next;
    try {
      await SettingsStore.save(next);
    } catch (err) {
      this.toast('保存设置失败：' + (err as Error).message);
      return;
    }
    if (appearanceChanged) {
      this.applyColorMode(next.colorMode);
    }
    if (previous.sortMode !== next.sortMode) {
      await this.reload();
    }
    await WidgetBridge.refreshAll(this.ctx);
  }

  private changeSortMode(key: number): void {
    const next: AppSettings = this.settings.copy();
    next.sortMode = key;
    this.saveSettings(next, false);
  }

  private changeColorMode(key: number): void {
    const next: AppSettings = this.settings.copy();
    next.colorMode = key;
    this.saveSettings(next, true);
  }

  private changeWidgetLines(key: number): void {
    const next: AppSettings = this.settings.copy();
    next.widgetLines = key;
    this.saveSettings(next, false);
  }

  /** 字号档位标签：跟随系统时同时显示系统当前比例 */
  private fontModeLabel(): string {
    if (this.settings.fontMode === FONT_FOLLOW) {
      return `跟随系统 ${this.systemFontScale.toFixed(2)}×`;
    }
    return `自定义 ${fontRatioOf(this.settings.fontMode).toFixed(2)}×`;
  }

  /** 打开设置面板：顺带刷新系统字体比例，避免后台改过系统字号后显示过期 */
  private openSettings(): void {
    if (this.ctx !== undefined) {
      this.systemFontScale = FontScaleService.systemScale(this.ctx);
    }
    this.showSettings = true;
  }

  /** 关闭设置面板：底部导航「设置」高亮随之回到时间轴 */
  private closeSettings(): void {
    this.showSettings = false;
    if (this.navTab === 2) {
      this.navTab = 0;
    }
  }

  /** 同意协议：记录接受事实与协议版本，之后不再弹出 */
  private acceptAgreement(): void {
    this.agreed = true;
    PrefStore.put(KEY_AGREE_ACCEPTED, true).catch(() => {
    });
    PrefStore.put(KEY_AGREE_VERSION, AGREEMENT_VERSION).catch(() => {
    });
  }

  /** 不同意：退出应用（数据仍保留在本机，下次启动会再次询问） */
  private declineAgreement(): void {
    if (this.ctx !== undefined) {
      this.ctx.terminateSelf().catch(() => {
      });
    }
  }

  private changeFontMode(key: number): void {
    const next: AppSettings = this.settings.copy();
    next.fontMode = key;
    if (this.ctx !== undefined) {
      FontScaleService.applyNow(this.ctx, key);
    }
    this.saveSettings(next, false);
  }

  private confirmClearAll(): void {
    this.getUIContext().showAlertDialog({
      title: '清空本账号',
      message: `将删除「${this.account.name}」下的全部任务（含未完成），不可恢复。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: $r('app.color.danger'),
        action: () => {
          this.doClearAll();
        }
      }
    });
  }

  private async doClearAll(): Promise<void> {
    try {
      const repo: TaskRepository = TaskRepository.getInstance();
      await repo.clearAll();
      await this.afterChange();
      this.toast('已清空');
    } catch (err) {
      this.toast('清空失败：' + (err as Error).message);
    }
  }

  /* ==================== 操作 ==================== */

  private async addTask(quadrant: number, raw: string): Promise<void> {
    const title: string = raw.trim();
    if (title.length === 0) {
      return;
    }
    try {
      await TaskRepository.getInstance().insert(title, quadrant, 0, false);
      this.setInput(quadrant, '');
      await this.afterChange();
    } catch (err) {
      this.toast('添加失败：' + (err as Error).message);
    }
  }

  private async toggle(item: TaskItem): Promise<void> {
    try {
      await TaskRepository.getInstance().setCompleted(item.id, !item.completed);
      await this.afterChange();
    } catch (err) {
      this.toast('更新失败：' + (err as Error).message);
    }
  }

  private openEditor(item?: TaskItem): void {
    if (item !== undefined) {
      this.editingId = item.id;
      this.draftTitle = item.title;
      this.draftQuadrant = item.quadrant;
      this.draftDue = item.dueAt;
      this.draftImportant = item.important;
      this.draftDone = item.completed;
      this.editingDone = item.completed;
      this.draftDate = new Date(item.dueAt > 0 ? item.dueAt : Date.now());
    } else {
      this.editingId = 0;
      this.draftTitle = '';
      this.draftQuadrant = this.settings.defaultQuadrant;
      this.draftDue = 0;
      this.draftImportant = false;
      this.draftDone = false;
      this.editingDone = false;
      this.draftDate = new Date();
    }
    this.showCalendar = false;
    this.showEditor = true;
  }

  private async saveDraft(): Promise<void> {
    const title: string = this.draftTitle.trim();
    if (title.length === 0) {
      this.toast('标题不能为空');
      return;
    }
    const id: number = this.editingId;
    const quadrant: number = this.draftQuadrant;
    const due: number = this.draftDue;
    const important: boolean = this.draftImportant;
    // 先收面板，手感上「点了就存」，写库在后面几毫秒完成
    this.showEditor = false;
    const repo: TaskRepository = TaskRepository.getInstance();
    try {
      if (id > 0) {
        await repo.updateFields(id, title, quadrant, due, important);
        if (this.draftDone !== this.editingDone) {
          await repo.setCompleted(id, this.draftDone);
        }
      } else {
        const newId: number = await repo.insert(title, quadrant, due, important);
        if (this.draftDone) {
          await repo.setCompleted(newId, true);
        }
      }
      await this.afterChange();
    } catch (err) {
      this.toast('保存失败：' + (err as Error).message);
    }
  }

  private confirmDelete(id: number, title: string): void {
    this.getUIContext().showAlertDialog({
      title: '删除任务',
      message: `确定删除「${title}」？删除后不可恢复。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: $r('app.color.danger'),
        action: () => {
          this.doDelete(id);
        }
      }
    });
  }

  private async doDelete(id: number): Promise<void> {
    try {
      await TaskRepository.getInstance().remove(id);
      this.showEditor = false;
      await this.afterChange();
    } catch (err) {
      this.toast('删除失败：' + (err as Error).message);
    }
  }

  private confirmClearCompleted(): void {
    if (this.completedToday === 0) {
      this.toast('暂无可清理的已完成任务');
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '清理已完成',
      message: '将永久删除全部已完成任务，是否继续？',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清理',
        fontColor: $r('app.color.danger'),
        action: () => {
          this.doClearCompleted();
        }
      }
    });
  }

  private async doClearCompleted(): Promise<void> {
    try {
      const repo: TaskRepository = TaskRepository.getInstance();
      await repo.clearCompleted();
      await this.afterChange();
      this.toast('已清理');
    } catch (err) {
      this.toast('清理失败：' + (err as Error).message);
    }
  }

  /** 截止日期快捷项：offsetDays < 0 代表「清除」 */
  private isDuePicked(offsetDays: number): boolean {
    if (offsetDays < 0) {
      return this.draftDue === 0;
    }
    if (this.draftDue <= 0) {
      return false;
    }
    return DateUtil.startOfDay(this.draftDue) === DateUtil.dayOffset(offsetDays);
  }

  /* ==================== 华为账号 ==================== */

  private refreshHuaweiState(): void {
    const profile: HuaweiIdProfile | undefined = HuaweiAuthService.stored();
    if (profile !== undefined) {
      this.hwOpenId = profile.openId;
      this.hwNickName = profile.nickName;
      this.hwAvatar = profile.avatarUri;
    } else {
      this.hwOpenId = '';
      this.hwNickName = '';
      this.hwAvatar = '';
    }
  }

  private async hwLogin(): Promise<void> {
    if (this.hwBusy) {
      return;
    }
    if (this.ctx === undefined) {
      this.hwError = '界面上下文未就绪，请稍后再试';
      return;
    }
    this.hwBusy = true;
    this.hwError = '';
    try {
      const profile: HuaweiIdProfile = await HuaweiAuthService.login(this.ctx);
      this.refreshHuaweiState();
      this.refreshBackupState();
      this.toast(profile.nickName.length > 0 ? `已登录：${profile.nickName}` : '华为账号已登录');
    } catch (err) {
      this.hwError = (err as Error).message;
      await this.showHwErrorDialog();
    } finally {
      this.hwBusy = false;
    }
  }

  /** 登录失败要能看懂原因：错误码 + 缺哪一步配置，而不是一闪而过的提示 */
  private async showHwErrorDialog(): Promise<void> {
    let extra: string = '';
    const configured: boolean = await HuaweiAuthService.clientIdConfigured();
    if (!configured) {
      extra = '\n\n另：module.json5 里的 client_id 还是空的。需要在 AppGallery Connect 创建应用、开通「账号服务」，' +
        '把 Client ID 填进 client_id 后重新打包安装。';
    }
    const code: number = HuaweiAuthService.lastCode;
    const codeText: string = code === 0 ? '' : `（错误码 ${code}）`;
    this.getUIContext().showAlertDialog({
      title: '华为账号登录失败',
      message: `${this.hwError}${codeText}${extra}`,
      autoCancel: true,
      confirm: {
        value: '知道了',
        action: () => {
        }
      }
    });
  }

  private async hwLogout(): Promise<void> {
    try {
      if (this.ctx !== undefined) {
        await HuaweiAuthService.logout(this.ctx);
      }
      this.refreshHuaweiState();
      this.refreshBackupState();
      this.hwError = '';
      this.toast('已退出华为账号');
    } catch (err) {
      this.toast((err as Error).message);
    }
  }

  /* ==================== 云备份 ==================== */

  private refreshBackupState(): void {
    this.lastBackupText = BackupService.lastBackupText();
  }

  private async runAutoBackup(): Promise<void> {
    if (this.ctx === undefined) {
      return;
    }
    await BackupService.autoBackup(this.ctx);
    this.refreshBackupState();
  }

  private async doBackupNow(): Promise<void> {
    if (this.backupBusy || this.ctx === undefined) {
      return;
    }
    this.backupBusy = true;
    try {
      const result: BackupResult = await BackupService.backup(this.ctx);
      this.refreshBackupState();
      this.toast(result.message);
    } finally {
      this.backupBusy = false;
    }
  }

  private async doRestore(): Promise<void> {
    if (this.backupBusy || this.ctx === undefined) {
      return;
    }
    this.backupBusy = true;
    try {
      const result: BackupResult = await BackupService.restore(this.ctx);
      if (result.ok) {
        await this.afterChange();
      }
      this.toast(result.message);
    } finally {
      this.backupBusy = false;
    }
  }

  /** 导出到本地文件：不依赖华为账号 */
  private async doExportFile(): Promise<void> {
    if (this.backupBusy || this.ctx === undefined) {
      return;
    }
    this.backupBusy = true;
    try {
      const result: BackupResult = await BackupService.exportToFile(this.ctx);
      this.toast(result.message);
    } finally {
      this.backupBusy = false;
    }
  }

  /** 从本地文件恢复 */
  private async doImportFile(): Promise<void> {
    if (this.backupBusy || this.ctx === undefined) {
      return;
    }
    this.backupBusy = true;
    try {
      const result: BackupResult = await BackupService.importFromFile(this.ctx);
      if (result.ok) {
        await this.afterChange();
      }
      this.toast(result.message);
    } finally {
      this.backupBusy = false;
    }
  }

  private async toggleAutoBackup(on: boolean): Promise<void> {
    this.autoBackup = on;
    try {
      await BackupService.setAutoEnabled(on);
    } catch (err) {
      this.toast('保存失败：' + (err as Error).message);
    }
  }

  /* ==================== 视图 ==================== */

  @Builder
  Header() {
    Row() {
      Text(this.quoteLine())
        .fontSize(12)
        .fontColor($r('app.color.muted'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('已完成')
        .fontSize(12)
        .fontColor($r('app.color.fg'))
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .backgroundColor($r('app.color.card'))
        .borderRadius(13)
        .margin({ left: 10 })
        .onClick(() => {
          this.openDone();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 4 })
    .flexShrink(0)
  }

  @Builder
  Board() {
    Column({ space: 0 }) {
      Column() {
        Row({ space: 6 }) {
          ForEach(QUADRANTS, (meta: QuadrantMeta, index: number) => {
            this.QuadStatCell(meta)
          }, (meta: QuadrantMeta) => `quadstat-${meta.key}`)
        }
        .width('100%')
        .margin({ top: 8, bottom: 10 })

        Row() {
          Text('时间轴 · ' + (this.timelineFilter === 0
            ? '全部象限' : this.quadrantShort(this.timelineFilter)))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.fg'))
          Blank()
          Text('待办 ' + this.timelineTasks().length)
            .fontSize(12)
            .fontColor($r('app.color.muted'))
        }
        .width('100%')
        .margin({ bottom: 16 })

        if (this.timelineTasks().length === 0) {
          Column() {
            Text(this.timelineFilter === 0 ? '暂无待办' : '这个象限暂时没有待办')
              .fontSize(12)
              .fontColor($r('app.color.muted'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 0 }) {
            ForEach(this.timelineTasks(), (item: TaskItem) => {
              ListItem() {
                Row() {
                  this.TimelineTick(item)
                  this.TimelineCapsule(item)
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
              }
            }, (item: TaskItem) => `tl-${item.id}-${item.updatedAt}`)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, bottom: 8 })
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 顶部四象限统计条：点击筛选，与底部归类键共用筛选状态 */
  @Builder
  QuadStatCell(meta: QuadrantMeta) {
    Button() {
      Column() {
        Text('Q' + meta.key)
          .fontSize(12)
          .fontWeight(FontWeight.Bolder)
          .fontColor(this.quadrantDot(meta.key))
        Text(this.tasksOf(meta.key).length.toString())
          .fontSize(20)
          .fontWeight(FontWeight.Bolder)
          .fontColor(this.quadrantDot(meta.key))
          .margin({ top: 2 })
        Text(meta.name)
          .fontSize(12)
          .fontColor(this.quadrantDot(meta.key))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .height(64)
    .padding({ left: 6, right: 6, top: 8, bottom: 8 })
    .backgroundColor(this.quadBg(meta.key))
    .border({
      width: this.timelineFilter === meta.key ? 2 : 0,
      color: this.quadrantDot(meta.key)
    })
    .borderRadius(12)
    .onClick(() => {
      this.timelineFilter = this.timelineFilter === meta.key ? 0 : meta.key;
    })
  }

  /** 时间轴刻度：中文大写月份 + 日期号（或「未」）挂在线上；竖线逐行相接形成连续刻度轴 */
  @Builder
  TimelineTick(item: TaskItem) {
    Column() {
      Text(this.monthCN(item.dueAt))
        .fontSize(12)
        .fontColor($r('app.color.accent'))
        .width(44)
        .height(20)
        .textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.bg'))
      Text(item.dueAt > 0 ? new Date(item.dueAt).getDate().toString() : '未')
        .fontSize(12)
        .fontColor($r('app.color.muted'))
        .width(44)
        .height(20)
        .textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.bg'))
      Column()
        .width(1)
        .layoutWeight(1)
        .backgroundColor($r('app.color.border'))
    }
    .width(44)
    .height(80)
  }

  /** 时间轴上的一根胶囊：长度由截止日距离决定 */
  @Builder
  TimelineCapsule(item: TaskItem) {
    Row() {
      Stack() {
        if (DateUtil.isOverdue(item.dueAt)) {
          Text('!')
            .fontSize(10)
            .fontWeight(FontWeight.Bolder)
            .fontColor($r('app.color.on_accent'))
        }
      }
      .width(18)
      .height(18)
      .borderRadius(9)
      .backgroundColor(DateUtil.isOverdue(item.dueAt)
        ? $r('app.color.danger') : this.quadrantDot(item.quadrant))
      .margin({ right: 6 })

      Column() {
        Text(item.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.fg'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text('Q' + item.quadrant + ' · ' +
          (item.dueAt > 0 ? DateUtil.dueLabel(item.dueAt) : '未排期'))
          .fontSize(12)
          .fontColor(this.quadrantDot(item.quadrant))
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button() {
        Text('完成')
          .fontSize(12)
          .fontColor($r('app.color.muted'))
      }
      .width(48)
      .height(40)
      .borderRadius(20)
      .backgroundColor($r('app.color.transparent'))
      .border({ width: 1, color: $r('app.color.border') })
      .onClick(() => {
        this.toggle(item);
      })
    }
    .width(this.capsuleLen(item.dueAt))
    .height(72)
    .padding({ left: 12, right: 10, top: 8, bottom: 8 })
    .backgroundColor(this.quadBg(item.quadrant))
    .borderRadius(36)
    .onClick(() => {
      this.openEditor(item);
    })
  }

  /** 底部 C 式输入行：有字点键归入，无字点键筛选 */
  @Builder
  TimelineDock() {
    Column() {
      Row({ space: 8 }) {
        QuickInput({
          text: $timelineInput,
          placeholder: '记下要做的事，回车归位…',
          boxHeight: 40,
          fontSize: 14,
          boxBg: $r('app.color.bg'),
          onCommit: () => {
            this.commitTimelineInput();
          }
        })
        .layoutWeight(1)

        Text('归类')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(10)
          .onClick(() => {
            if (this.timelineInput.trim().length > 0) {
              this.commitTimelineInput();
            } else {
              this.toast('点下方象限键，只看这一类');
            }
          })
      }
      .width('100%')

      Row({ space: 6 }) {
        ForEach(QUADRANTS, (meta: QuadrantMeta) => {
          Row() {
            Row()
              .width(6)
              .height(6)
              .borderRadius(3)
              .backgroundColor(this.quadrantDot(meta.key))
              .margin({ right: 4 })
            Text(this.quadrantShort(meta.key))
              .fontSize(12)
              .fontColor(this.quadrantDot(meta.key))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .height(40)
          .justifyContent(FlexAlign.Center)
          .borderRadius(10)
          .border({ width: 1, color: this.quadrantDot(meta.key) })
          .backgroundColor(this.timelineFilter === meta.key
            ? this.quadBg(meta.key) : $r('app.color.transparent'))
          .onClick(() => {
            this.addToQuadrant(meta.key);
          })
        }, (meta: QuadrantMeta) => `qkey-${meta.key}`)
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: this.keyboardVisible ? 0 : 12 })
    .border({ width: { top: 1 }, color: $r('app.color.border') })
  }

  /** 底部导航栏：时间轴 / 归类 / 设置（三个等宽 tab，图标 + 文字，无加号）
   *  键盘弹起时隐藏：否则 RESIZE 会把导航栏顶到键盘上方，看起来跟着上弹并挡住输入区 */
  @Builder
  BottomNav() {
    if (!this.keyboardVisible) {
      Row() {
        this.NavItem(0, '时间轴', $r('sys.symbol.clock'))
        this.NavItem(1, '归类', $r('sys.symbol.square_grid_2x2'))
        this.NavItem(2, '设置', $r('sys.symbol.gearshape'))
      }
      .width('100%')
      .height(56)
      .padding({ left: 8, right: 8 })
      // 与页面主体及底部安全区同为 bg，避免导航栏与其下方出现色差
      .backgroundColor($r('app.color.bg'))
      .border({ width: { top: 1 }, color: $r('app.color.border') })
      .flexShrink(0)
    }
  }

  @Builder
  NavItem(tab: number, label: string, icon: Resource) {
    Column({ space: 2 }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([this.navTab === tab ? $r('app.color.accent') : $r('app.color.muted')])
      Text(label)
        .fontSize(12)
        .fontWeight(this.navTab === tab ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.navTab === tab ? $r('app.color.accent') : $r('app.color.muted'))
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    // 图标+文字整体随点击缩放，Spring 曲线产生回弹手感
    .scale({ x: this.navBounceTab === tab ? 0.86 : 1.0, y: this.navBounceTab === tab ? 0.86 : 1.0 })
    .animation({ duration: 300, curve: curves.springMotion() })
    .onClick(() => {
      // 点击弹跳：先置缩小态，短暂延时后回弹
      this.navBounceTab = tab;
      setTimeout(() => {
        this.navBounceTab = -1;
      }, 120);
      // 编辑页/已完成面板打开时，先关闭覆盖层再切页
      if (this.showEditor) {
        this.showEditor = false;
      }
      if (this.showDone) {
        this.showDone = false;
      }
      this.navTab = tab;
      if (tab === 2) {
        this.openSettings();
      }
    })
  }

  /** 归类页：本周负载柱状图 + 象限筛选 + 本周待办列表（B 方案第 3 屏） */
  @Builder
  WeekPage() {
    Column() {
      Row() {
        Text('本周待办')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.fg'))
        Blank()
        Text('本周 ' + this.weekTotal() + ' 件')
          .fontSize(12)
          .fontColor($r('app.color.muted'))
      }
      .width('100%')
      .padding({ top: 8, bottom: 4 })

      Row({ space: 6 }) {
        ForEach(['一', '二', '三', '四', '五', '六', '日'], (d: string, i: number) => {
          Column() {
            Column()
              .width(20)
              .height(this.dayBarHeight(i))
              .borderRadius(10)
              .backgroundColor(this.isTodayColumn(i)
                ? $r('app.color.accent') : $r('app.color.accent_soft'))
            Column({ space: 2 }) {
              Text(new Date(this.weekDay(i)).getDate().toString())
                .fontSize(12)
                .fontColor($r('app.color.fg'))
              Text('周' + d)
                .fontSize(12)
                .fontColor(this.isTodayColumn(i)
                  ? $r('app.color.accent') : $r('app.color.muted'))
            }
            .margin({ top: 6 })
          }
          .layoutWeight(1)
          .height('100%')
          // 每列等高 + 内容贴底：柱子按数据高矮往上长，下方星期/日期文字统一落在同一水平线
          .justifyContent(FlexAlign.End)
        }, (d: string, i: number) => `weekday-${i}`)
      }
      .width('100%')
      .height(150)
      .padding({ top: 14, bottom: 8 })
      .margin({ top: 10, bottom: 6 })
      .backgroundColor($r('app.color.card'))
      .borderRadius(16)

      Text('按象限筛选')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.fg'))
        .width('100%')
        .margin({ top: 6, bottom: 4 })

      Flex({ wrap: FlexWrap.Wrap }) {
        Text('全部')
          .fontSize(12)
          .fontColor(this.timelineFilter === 0
            ? $r('app.color.on_accent') : $r('app.color.fg'))
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(this.timelineFilter === 0
            ? $r('app.color.accent') : $r('app.color.bg'))
          .borderRadius(12)
          .margin({ right: 8, bottom: 8 })
          .onClick(() => {
            this.timelineFilter = 0;
          })
        ForEach(QUADRANTS, (meta: QuadrantMeta) => {
          Text(this.quadrantShort(meta.key))
            .fontSize(12)
            .fontColor(this.timelineFilter === meta.key
              ? $r('app.color.on_accent') : this.quadrantDot(meta.key))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.timelineFilter === meta.key
              ? this.quadrantDot(meta.key) : this.quadBg(meta.key))
            .borderRadius(12)
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.timelineFilter = meta.key;
            })
        }, (meta: QuadrantMeta) => `weekfilter-${meta.key}`)
      }
      .width('100%')

      Scroll() {
        Column({ space: 6 }) {
          if (this.weekTasks().length === 0) {
            Text('该范围本周暂无待办')
              .fontSize(12)
              .fontColor($r('app.color.muted'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 24 })
          } else {
            ForEach(this.weekTasks(), (item: TaskItem) => {
              Row({ space: 10 }) {
                Column()
                  .width(4)
                  .height(34)
                  .borderRadius(2)
                  .backgroundColor(this.quadrantDot(item.quadrant))
                Column({ space: 2 }) {
                  Text(item.title)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.fg'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .decoration(item.completed
                      ? { type: TextDecorationType.LineThrough, color: $r('app.color.muted') }
                      : { type: TextDecorationType.None, color: $r('app.color.fg') })
                  Text((item.completed ? '已完成 · ' : '') + this.quadrantShort(item.quadrant)
                    + ' · ' + DateUtil.dueLabel(item.dueAt))
                    .fontSize(12)
                    .fontColor($r('app.color.muted'))
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding({ top: 8, bottom: 8 })
              .backgroundColor($r('app.color.card'))
              .borderRadius(12)
              .onClick(() => {
                this.openEditor(item);
              })
            }, (item: TaskItem) => `weektask-${item.id}-${item.updatedAt}`)
          }
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 16, right: 16 })
  }

  /** 本周柱状图某天柱高：按本周最大值归一，最小 6vp */
  private dayBarHeight(i: number): number {
    const n: number = this.weekDayCount(this.weekDay(i));
    if (n <= 0) {
      return 6;
    }
    let max: number = 1;
    for (let k = 0; k < 7; k++) {
      const c: number = this.weekDayCount(this.weekDay(k));
      if (c > max) {
        max = c;
      }
    }
    return 6 + Math.round(n / max * 60);
  }

  private isTodayColumn(i: number): boolean {
    return DateUtil.startOfDay(this.weekDay(i)) === DateUtil.todayStart();
  }

  @Builder
  TaskCard(item: TaskItem) {
    Row() {
      Stack() {
        if (item.completed) {
          Text('✓')
            .fontSize(11)
            .fontColor($r('app.color.on_accent'))
        }
      }
      .width(18)
      .height(18)
      .borderRadius(9)
      .backgroundColor(item.completed ? $r('app.color.accent') : $r('app.color.transparent'))
      .border({
        width: 1.5,
        color: item.completed ? $r('app.color.accent') : $r('app.color.border')
      })
      .margin({ top: 1 })
      .onClick(() => {
        this.toggle(item);
      })

      Column() {
        Text(item.title)
          .fontSize(13)
          .fontColor(item.completed ? $r('app.color.muted') : $r('app.color.fg'))
          .decoration({
            type: item.completed ? TextDecorationType.LineThrough : TextDecorationType.None,
            color: $r('app.color.muted')
          })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        if (item.dueAt > 0 || item.important) {
          Row() {
            if (item.important) {
              Text('★')
                .fontSize(10)
                .fontColor($r('app.color.danger'))
                .margin({ right: 3 })
            }
            if (item.dueAt > 0) {
              Text(DateUtil.dueLabel(item.dueAt))
                .fontSize(10)
                .fontColor(DateUtil.isOverdue(item.dueAt) ? $r('app.color.danger') : $r('app.color.muted'))
            }
          }
          .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 6 })
    }
    .width('100%')
    .padding({ left: 7, right: 7, top: 6, bottom: 6 })
    .backgroundColor($r('app.color.card'))
    .borderRadius(8)
    .border({ width: 0.5, color: $r('app.color.border') })
    .onClick(() => {
      this.openEditor(item);
    })
    .gesture(
      LongPressGesture({ repeat: false })
        .onAction(() => {
          this.confirmDelete(item.id, item.title);
        })
    )
  }

  @Builder
  DueChip(label: string, offsetDays: number) {
    Text(label)
      .fontSize(12)
      .fontColor(this.isDuePicked(offsetDays) ? $r('app.color.on_accent') : $r('app.color.fg'))
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(this.isDuePicked(offsetDays) ? $r('app.color.accent') : $r('app.color.bg'))
      .borderRadius(12)
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.draftDue = offsetDays < 0 ? 0 : DateUtil.dayOffset(offsetDays);
        if (offsetDays >= 0) {
          this.draftDate = new Date(this.draftDue);
        }
        this.showCalendar = false;
      })
  }

  @Builder
  EditorPanel() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.scrim'))
        .onClick(() => {
          this.showEditor = false;
        })

      Column() {
        Row() {
          Text(this.editingId > 0 ? '编辑任务' : '新建任务')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.fg'))
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor($r('app.color.muted'))
            .padding(6)
            .onClick(() => {
              this.showEditor = false;
            })
        }
        .width('100%')

        QuickInput({
          text: $draftTitle,
          placeholder: '要做什么？',
          boxHeight: 44,
          fontSize: 15,
          boxBg: $r('app.color.bg'),
          topMargin: 12,
          onCommit: () => {
            this.saveDraft();
          }
        })

        if (this.editingId > 0) {
          Text('移动到其它象限')
            .fontSize(12)
            .fontColor($r('app.color.muted'))
            .width('100%')
            .margin({ top: 16 })

          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(QUADRANTS, (meta: QuadrantMeta) => {
              Text(meta.name)
                .fontSize(12)
                .fontColor(this.draftQuadrant === meta.key ? $r('app.color.on_accent') : $r('app.color.fg'))
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor(this.draftQuadrant === meta.key ? $r('app.color.accent') : this.quadBg(meta.key))
                .borderRadius(12)
                .margin({ right: 8, top: 8 })
                .onClick(() => {
                  this.draftQuadrant = meta.key;
                })
            }, (meta: QuadrantMeta) => `pick-${meta.key}`)
          }
          .width('100%')
        } else {
          Text(`将放入「${this.quadrantName(this.draftQuadrant)}」`)
            .fontSize(12)
            .fontColor($r('app.color.muted'))
            .width('100%')
            .margin({ top: 14 })
        }

        Row() {
          Text('截止日期')
            .fontSize(12)
            .fontColor($r('app.color.muted'))
            .layoutWeight(1)
          Text(this.draftDue > 0 ? DateUtil.dueLabel(this.draftDue) : '未设置')
            .fontSize(12)
            .fontColor(DateUtil.isOverdue(this.draftDue) ? $r('app.color.danger') : $r('app.color.fg'))
        }
        .width('100%')
        .margin({ top: 16 })

        Flex({ wrap: FlexWrap.Wrap }) {
          this.DueChip('今天', 0)
          this.DueChip('明天', 1)
          this.DueChip('后天', 2)
          this.DueChip('清除', -1)
          Text(this.showCalendar ? '收起日历' : '选日期')
            .fontSize(12)
            .fontColor($r('app.color.accent'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor($r('app.color.accent_soft'))
            .borderRadius(12)
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.showCalendar = !this.showCalendar;
            })
        }
        .width('100%')
        .margin({ top: 8 })

        if (this.showCalendar) {
          CalendarPicker({ hintRadius: 12, selected: this.draftDate })
            .width('100%')
            .onChange((value: Date) => {
              this.draftDate = value;
              this.draftDue = DateUtil.startOfDay(value.getTime());
            })
        }

        Row() {
          Text('标记为重要')
            .fontSize(13)
            .fontColor($r('app.color.fg'))
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.draftImportant })
            .selectedColor($r('app.color.accent'))
            .onChange((isOn: boolean) => {
              this.draftImportant = isOn;
            })
        }
        .width('100%')
        .margin({ top: 14 })

        Row({ space: 10 }) {
          if (this.editingId > 0) {
            Button() {
              Text('删除')
                .fontSize(14)
                .fontColor($r('app.color.danger'))
            }
            .layoutWeight(1)
            .constraintSize({ minHeight: 44 })
            .backgroundColor($r('app.color.bg'))
            .onClick(() => {
              this.confirmDelete(this.editingId, this.draftTitle);
            })
          }
          Button() {
            Text(this.editingId > 0 ? '保存' : '添加')
              .fontSize(14)
              .fontColor($r('app.color.on_accent'))
          }
          .layoutWeight(1)
          .constraintSize({ minHeight: 44 })
          .backgroundColor($r('app.color.accent'))
          .onClick(() => {
            this.saveDraft();
          })
        }
        .width('100%')
        .margin({ top: 18 })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 18, bottom: 22 })
      .backgroundColor($r('app.color.card'))
      .borderRadius({ topLeft: 20, topRight: 20 })
      .constraintSize({ maxHeight: '92%' })
    }
    .width('100%')
    .height('100%')
  }

  /** 全屏待办任务编辑页（＋ 入口，参考 B 方案编辑屏） */
  /**
   * B 方案屏幕 2「任务编辑」：顶栏 编辑/时间轴 + 右侧「编辑任务」，
   * 标题 / 象限 / 截止日 / 当前状态分组，底部保存 + 删除，底部两个 tab。
   */
  @Builder
  FullTaskEditor() {
    Column() {
      // 顶栏：编辑 / 时间轴（胶囊 tab）+ 右侧「编辑任务」
      Row() {
        Text('编辑')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor($r('app.color.accent_soft'))
          .borderRadius(18)
        Text('时间轴')
          .fontSize(14)
          .fontColor($r('app.color.muted'))
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onClick(() => {
            this.showEditor = false;
            this.navTab = 0;
          })
        Blank()
        Text('编辑任务')
          .fontSize(12)
          .fontColor($r('app.color.muted'))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .flexShrink(0)

      Scroll() {
        Column() {
          Text('任务编辑')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.fg'))
            .width('100%')
            .margin({ top: 10 })
          Text('截止日会改变轴上胶囊的长度')
            .fontSize(12)
            .fontColor($r('app.color.muted'))
            .width('100%')
            .margin({ top: 2, bottom: 16 })

          // 任务标题
          Text('任务标题')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.muted'))
            .width('100%')
            .margin({ bottom: 8 })
          QuickInput({
            text: $draftTitle,
            placeholder: '要做什么？',
            boxHeight: 46,
            fontSize: 14,
            boxBg: $r('app.color.card'),
            onCommit: () => {
              this.saveDraft();
            }
          })

          // 所属象限：Q1 / Q2 / Q3 / Q4
          Text('所属象限')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.muted'))
            .width('100%')
            .margin({ top: 20, bottom: 8 })
          Row({ space: 7 }) {
            ForEach(QUADRANTS, (meta: QuadrantMeta) => {
              Text(this.quadrantTag(meta.key))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.draftQuadrant === meta.key
                  ? this.quadrantDot(meta.key) : $r('app.color.fg'))
                .height(44)
                .layoutWeight(1)
                .textAlign(TextAlign.Center)
                .backgroundColor(this.draftQuadrant === meta.key
                  ? this.quadBg(meta.key) : $r('app.color.card'))
                .border({
                  width: 1,
                  color: this.draftQuadrant === meta.key
                    ? this.quadrantDot(meta.key) : $r('app.color.border')
                })
                .borderRadius(10)
                .onClick(() => {
                  this.draftQuadrant = meta.key;
                  this.draftImportant = meta.key === Q1 || meta.key === Q2;
                })
            }, (meta: QuadrantMeta) => `bq-${meta.key}`)
          }
          .width('100%')

          // 截止日（决定胶囊长度）：今天 / 明天 / 周五 / 未排期
          Text('截止日（决定胶囊长度）')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.muted'))
            .width('100%')
            .margin({ top: 20, bottom: 8 })
          Row({ space: 7 }) {
            this.EditorDueChip('今天', DateUtil.todayStart())
            this.EditorDueChip('明天', DateUtil.dayOffset(1))
            this.EditorDueChip('周五', this.fridayDue())
            this.EditorDueChip('未排期', 0)
          }
          .width('100%')

          // 当前状态：整宽按钮，点此切换完成状态
          Text('当前状态')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.muted'))
            .width('100%')
            .margin({ top: 20, bottom: 8 })
          Text(this.draftDone ? '已完成 · 点此恢复为待办' : '待办中 · 点此标记完成')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.draftDone ? $r('app.color.accent') : $r('app.color.fg'))
            .width('100%')
            .height(46)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.draftDone ? $r('app.color.accent_soft') : $r('app.color.card'))
            .border({ width: 1, color: $r('app.color.border') })
            .borderRadius(10)
            .onClick(() => {
              this.draftDone = !this.draftDone;
            })

          Button() {
            Text('保存并返回')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.on_accent'))
          }
          .width('100%')
          .height(48)
          .borderRadius(12)
          .backgroundColor($r('app.color.accent'))
          .margin({ top: 24 })
          .onClick(() => {
            this.saveDraft();
          })

          if (this.editingId > 0) {
            Button() {
              Text('删除任务')
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.danger'))
            }
            .width('100%')
            .height(44)
            .borderRadius(12)
            .backgroundColor($r('app.color.card'))
            .border({ width: 1, color: $r('app.color.border') })
            .margin({ top: 10, bottom: 24 })
            .onClick(() => {
              this.confirmDelete(this.editingId, this.draftTitle);
            })
          }
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 2, bottom: 18 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)

      // 底部导航：与主页共用同一组件（带图标），编辑页置灰时间轴外的项由点击关闭覆盖层
      this.BottomNav()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
  }

  @Builder
  EditorDueChip(label: string, dueAt: number) {
    Text(label)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(DateUtil.startOfDay(this.draftDue) === dueAt || (dueAt === 0 && this.draftDue === 0)
        ? $r('app.color.accent') : $r('app.color.fg'))
      .height(44)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .backgroundColor(DateUtil.startOfDay(this.draftDue) === dueAt || (dueAt === 0 && this.draftDue === 0)
        ? $r('app.color.accent_soft') : $r('app.color.card'))
      .border({
        width: 1,
        color: DateUtil.startOfDay(this.draftDue) === dueAt || (dueAt === 0 && this.draftDue === 0)
          ? $r('app.color.accent') : $r('app.color.border')
      })
      .borderRadius(10)
      .onClick(() => {
        this.draftDue = dueAt;
      })
  }

  @Builder
  RulerSection(title: string, body: string) {
    Column({ space: 4 }) {
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.fg'))
      Text(body)
        .fontSize(12)
        .fontColor($r('app.color.muted'))
        .lineHeight(19)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  RulerPanel() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.scrim'))
        .onClick(() => {
          this.showRuler = false;
        })

      Column() {
        Row() {
          Text('归类说明')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.fg'))
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor($r('app.color.muted'))
            .padding(6)
            .onClick(() => {
              this.showRuler = false;
            })
        }
        .width('100%')

        Scroll() {
          Column({ space: 14 }) {
            this.RulerSection('重要',
              '会影响钱、岗位、口碑、健康、长期可积累技能的，一律算重要。判断标准是「半年后还重不重要」，而不是「现在有没有人催」。')
            this.RulerSection('不重要',
              '可代劳、可拒绝、对上面几项几乎无影响的事务性琐事。这类事做得再漂亮，也不会改变你的处境。')
            this.RulerSection('紧急',
              '有硬性截止时间，或者再拖下去会真的出问题（罚款、误机、关系破裂、身体报警）。')
            this.RulerSection('不紧急',
              '没有硬截止，但拖久了会让「重要不紧急」变成「重要紧急」。这是大多数人长期焦虑的真正来源。')

            Column({ space: 8 }) {
              Text('四格怎么用')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.fg'))
              ForEach(QUADRANTS, (meta: QuadrantMeta) => {
                Row() {
                  Text(meta.name)
                    .fontSize(12)
                    .fontColor($r('app.color.fg'))
                    .width(88)
                  Text(meta.hint)
                    .fontSize(12)
                    .fontColor($r('app.color.muted'))
                    .layoutWeight(1)
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
              }, (meta: QuadrantMeta) => `rule-${meta.key}`)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')

            Text('口诀：上午啃「重要不紧急」；中午到下午清「重要紧急」；碎片时间批量处理「紧急不重要」；第四格只在闲时碰。')
              .fontSize(12)
              .fontColor($r('app.color.muted'))
              .lineHeight(19)
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ top: 12 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)

        Row({ space: 10 }) {
          Text('清理已完成')
            .fontSize(12)
            .fontColor($r('app.color.danger'))
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.bg'))
            .borderRadius(12)
            .onClick(() => {
              this.confirmClearCompleted();
            })
          Text('桌面卡片')
            .fontSize(12)
            .fontColor($r('app.color.accent'))
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.accent_soft'))
            .borderRadius(12)
            .onClick(() => {
              this.showRuler = false;
              this.openSettings();
            })
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('100%')
      .height('62%')
      .padding({ left: 18, right: 18, top: 18, bottom: 22 })
      .backgroundColor($r('app.color.card'))
      .borderRadius({ topLeft: 20, topRight: 20 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  DonePanel() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.scrim'))
        .onClick(() => {
          this.showDone = false;
        })

      Column() {
        Row() {
          Text('已完成')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.fg'))
          Text(` ${this.doneTasks.length} 项`)
            .fontSize(12)
            .fontColor($r('app.color.muted'))
            .layoutWeight(1)
          Text('✕')
            .fontSize(16)
            .fontColor($r('app.color.muted'))
            .padding(6)
            .onClick(() => {
              this.showDone = false;
            })
        }
        .width('100%')

        if (this.doneTasks.length === 0) {
          Column() {
            Text('还没有已完成的任务')
              .fontSize(12)
              .fontColor($r('app.color.muted'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 0 }) {
            ForEach(this.doneTasks, (item: TaskItem) => {
              ListItem() {
                Row() {
                  Text(item.title)
                    .fontSize(13)
                    .fontColor($r('app.color.muted'))
                    .decoration({ type: TextDecorationType.LineThrough, color: $r('app.color.muted') })
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)

                  Text('恢复')
                    .fontSize(11)
                    .fontColor($r('app.color.accent'))
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .backgroundColor($r('app.color.accent_soft'))
                    .borderRadius(10)
                    .onClick(() => {
                      this.restoreTask(item);
                    })

                  Text('删除')
                    .fontSize(11)
                    .fontColor($r('app.color.danger'))
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .backgroundColor($r('app.color.bg'))
                    .borderRadius(10)
                    .margin({ left: 6 })
                    .onClick(() => {
                      this.confirmDelete(item.id, item.title);
                    })
                }
                .width('100%')
                .padding({ top: 9, bottom: 9 })
                .border({ width: { bottom: 0.5 }, color: $r('app.color.border') })
              }
            }, (item: TaskItem) => `done-${item.id}-${item.updatedAt}`)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .padding({ top: 6 })
        }
      }
      .width('100%')
      .height('62%')
      .padding({ left: 18, right: 18, top: 18, bottom: 22 })
      .backgroundColor($r('app.color.card'))
      .borderRadius({ topLeft: 20, topRight: 20 })
    }
    .width('100%')
    .height('100%')
  }

  /** 设置分组标题：灰色小字，位于卡片外（参考系统设置风格） */
  @Builder
  GroupTitle(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor($r('app.color.muted'))
      .width('100%')
      .margin({ top: 18, bottom: 8 })
  }

  /** 设置卡片内的行分隔线 */
  @Builder
  RowDivider() {
    Divider()
      .strokeWidth(0.5)
      .color($r('app.color.border'))
  }

  /** 设置选项 chip */
  @Builder
  OptChip(label: string, selected: boolean) {
    Text(label)
      .fontSize(11)
      .fontColor(selected ? $r('app.color.on_accent') : $r('app.color.fg'))
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .backgroundColor(selected ? $r('app.color.accent') : $r('app.color.bg'))
      .borderRadius(12)
  }

  /** 设置页统一操作按钮：同底色同字号（11），危险操作用红字 */
  @Builder
  Chip(label: string, onTap: () => void, danger: boolean) {
    Text(label)
      .fontSize(11)
      .fontColor(danger ? $r('app.color.danger') : $r('app.color.fg'))
      .padding({ left: 11, right: 11, top: 6, bottom: 6 })
      .backgroundColor($r('app.color.bg'))
      .borderRadius(10)
      .onClick(() => {
        onTap();
      })
  }

  @Builder
  HintText(text: string) {
    Text(text)
      .fontSize(10)
      .fontColor($r('app.color.muted'))
      .width('100%')
      .margin({ top: 4 })
  }

  @Builder
  AgreementSection(title: string, body: string) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.fg'))
      Text(body)
        .fontSize(13)
        .lineHeight(22)
        .fontColor($r('app.color.fg'))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 首启用户协议页：全屏覆盖，同意前无法使用应用 */
  @Builder
  AgreementPanel() {
    Column() {
      Text('用户协议')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.fg'))
        .width('100%')
      Text('请完整阅读用户协议与免责声明')
        .fontSize(12)
        .fontColor($r('app.color.muted'))
        .width('100%')
        .margin({ top: 4 })

      Scroll() {
        Column({ space: 16 }) {
          Text('在使用 象限待办（下称「本软件」）之前，请仔细阅读并充分理解本协议与免责声明。点击「同意并继续」即视为您已阅读、理解并同意接受全部内容；如不同意，请点击「不同意并退出」，停止使用本软件。')
            .fontSize(13)
            .lineHeight(22)
            .fontColor($r('app.color.fg'))
            .width('100%')

          this.AgreementSection('一、软件性质与知识产权',
            '本软件由作者独立开发，源码通过 GitHub（仓库 quadrant-todo）公开，供学习研究与非商业使用；软件的界面设计、图标、文档等内容归作者所有。请在遵循仓库附带许可的前提下使用与分发，不得去除或篡改本软件的版权与来源声明后再分发，不得将本软件用于任何违法违规用途。')

          this.AgreementSection('二、数据与隐私',
            '任务数据默认仅保存在本机数据库中，本软件不会在后台上传您的任何数据。仅当您主动开启「云备份」「本机日历」「日历订阅」等功能时，相关数据才会传输到对应第三方服务，且可随时在设置中关闭。卸载本软件即清除全部本地数据。')

          this.AgreementSection('三、第三方服务',
            '华为账号、Gitee、系统日历等功能依赖相应第三方提供的服务，其可用性、准确性与安全性由服务提供方负责，作者对第三方服务的变更或中断不承担责任。')

          this.AgreementSection('四、免责声明',
            '本软件按「现状」提供，不作出任何形式的担保。因系统故障、误操作、卸载重装或其他原因导致的任务数据丢失或损坏，作者不承担责任；重要数据请通过「云备份」或「导出备份」定期自行备份。本软件写入系统日历、日历订阅等功能在具体设备上的实际表现以真机为准。')

          this.AgreementSection('五、协议的更新',
            '本协议可能随版本更新而调整。协议内容发生实质变更后，应用将在下次启动时重新提示确认；若您在提示后继续使用本软件，即视为接受更新后的协议。')
        }
        .width('100%')
        .padding({ top: 10, bottom: 10 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)
      .margin({ top: 14 })

      Button() {
        Text('同意并继续')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_accent'))
      }
      .width('100%')
      .height(44)
      .backgroundColor($r('app.color.accent'))
      .onClick(() => {
        this.acceptAgreement();
      })

      Button() {
        Text('不同意并退出')
          .fontSize(15)
          .fontColor($r('app.color.fg'))
      }
      .width('100%')
      .height(44)
      .backgroundColor($r('app.color.card'))
      .margin({ top: 10 })
      .onClick(() => {
        this.declineAgreement();
      })
    }
    .width('100%')
    .height('100%')
    .padding(20)
    .backgroundColor($r('app.color.bg'))
  }

  @Builder
  SettingsPanel() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.scrim'))
        .onClick(() => {
          this.closeSettings();
        })

      Column() {
        Row() {
          Text('设置')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.fg'))
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor($r('app.color.muted'))
            .padding(6)
            .onClick(() => {
              this.closeSettings();
            })
        }
        .width('100%')

        Scroll() {
          Column() {
            /* ==================== 通用 ==================== */
            this.GroupTitle('通用')
            Column() {
              Column() {
                Text('任务排序')
                  .fontSize(14)
                  .fontColor($r('app.color.fg'))
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(SORT_OPTIONS, (opt: SettingOption) => {
                    Row() {
                      this.OptChip(opt.label, this.settings.sortMode === opt.key)
                    }
                    .onClick(() => {
                      this.changeSortMode(opt.key);
                    })
                    .margin({ right: 8, top: 8 })
                  }, (opt: SettingOption) => `sort-${opt.key}-${this.settings.sortMode === opt.key ? 1 : 0}`)
                }
                .width('100%')
                .margin({ top: 10 })
              }
              .width('100%')
              .padding({ top: 13, bottom: 13 })
              .alignItems(HorizontalAlign.Start)
              this.RowDivider()

              Column() {
                Text('外观')
                  .fontSize(14)
                  .fontColor($r('app.color.fg'))
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(COLOR_MODE_OPTIONS, (opt: SettingOption) => {
                    Row() {
                      this.OptChip(opt.label, this.settings.colorMode === opt.key)
                    }
                    .onClick(() => {
                      this.changeColorMode(opt.key);
                    })
                    .margin({ right: 8, top: 8 })
                  }, (opt: SettingOption) => `mode-${opt.key}-${this.settings.colorMode === opt.key ? 1 : 0}`)
                }
                .width('100%')
                .margin({ top: 10 })
                Text('「跟随系统」与系统深色模式同步，切换后立即生效')
                  .fontSize(10)
                  .fontColor($r('app.color.muted'))
                  .margin({ top: 8 })
              }
              .width('100%')
              .padding({ top: 13, bottom: 13 })
              .alignItems(HorizontalAlign.Start)
              this.RowDivider()

              Column() {
                Row() {
                  Text('字体大小')
                    .fontSize(14)
                    .fontColor($r('app.color.fg'))
                    .layoutWeight(1)
                  Text(this.fontModeLabel())
                    .fontSize(12)
                    .fontColor($r('app.color.muted'))
                }
                .width('100%')

                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(FONT_MODE_OPTIONS, (opt: SettingOption) => {
                    Row() {
                      this.OptChip(opt.label, this.settings.fontMode === opt.key)
                    }
                    .onClick(() => {
                      this.changeFontMode(opt.key);
                    })
                    .margin({ right: 8, top: 8 })
                  }, (opt: SettingOption) => `font-${opt.key}-${this.settings.fontMode === opt.key ? 1 : 0}`)
                }
                .width('100%')
                .margin({ top: 10 })

                Text(this.settings.fontMode === FONT_FOLLOW
                  ? '字号随系统「设置 → 显示和亮度 → 字体大小」变化，应用最多放大 1.75 倍'
                  : '自定义档位覆盖系统字号；改回「跟随系统」后重新打开应用即恢复跟随')
                  .fontSize(10)
                  .fontColor($r('app.color.muted'))
                  .margin({ top: 8 })
              }
              .width('100%')
              .padding({ top: 13, bottom: 13 })
              .alignItems(HorizontalAlign.Start)
              this.RowDivider()

              Column() {
                Text('大卡片（6*4）显示条数')
                  .fontSize(14)
                  .fontColor($r('app.color.fg'))
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(WIDGET_LINE_OPTIONS, (opt: SettingOption) => {
                    Row() {
                      this.OptChip(opt.label, this.settings.widgetLines === opt.key)
                    }
                    .onClick(() => {
                      this.changeWidgetLines(opt.key);
                    })
                    .margin({ right: 8, top: 8 })
                  }, (opt: SettingOption) => `lines-${opt.key}-${this.settings.widgetLines === opt.key ? 1 : 0}`)
                }
                .width('100%')
                .margin({ top: 10 })
              }
              .width('100%')
              .padding({ top: 13, bottom: 13 })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: 14, right: 14 })
            .backgroundColor($r('app.color.card'))
            .borderRadius(16)
            .alignItems(HorizontalAlign.Start)

            /* ==================== 备份（本地文件导入导出） ==================== */
            this.GroupTitle('备份')
            Column() {
              Row() {
                Text('自动备份')
                  .fontSize(14)
                  .fontColor($r('app.color.fg'))
                  .layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.autoBackup })
                  .selectedColor($r('app.color.accent'))
                  .onChange((isOn: boolean) => {
                    this.toggleAutoBackup(isOn);
                  })
              }
              .width('100%')
              .padding({ top: 6, bottom: 6 })
              this.RowDivider()

              Row({ space: 8 }) {
                this.Chip(this.backupBusy ? '处理中…' : '备份到云端', () => {
                  this.doBackupNow();
                }, false)
                this.Chip('从云端恢复', () => {
                  this.doRestore();
                }, false)
                Blank()
                Text(this.lastBackupText.length > 0 ? `上次：${this.lastBackupText}` : '尚未备份')
                  .fontSize(10)
                  .fontColor($r('app.color.muted'))
              }
              .width('100%')
              .padding({ top: 12, bottom: 12 })
              this.RowDivider()

              Row({ space: 8 }) {
                this.Chip('导出到文件', () => {
                  this.doExportFile();
                }, false)
                this.Chip('从文件恢复', () => {
                  this.doImportFile();
                }, false)
              }
              .width('100%')
              .padding({ top: 12, bottom: 12 })
              this.RowDivider()
              Text('导出/导入走系统文件选择器，备份文件保存在本机')
                .fontSize(10)
                .fontColor($r('app.color.muted'))
                .width('100%')
                .padding({ top: 10, bottom: 12 })
            }
            .width('100%')
            .padding({ left: 14, right: 14 })
            .backgroundColor($r('app.color.card'))
            .borderRadius(16)
            .alignItems(HorizontalAlign.Start)

            /* ==================== 本机日历 ==================== */
            this.GroupTitle('本机日历')
            Column() {
              Row() {
                Column() {
                  Text('同步到系统日历')
                    .fontSize(14)
                    .fontColor($r('app.color.fg'))
                  Text(this.localCalEnabled ?
                    (this.localCalLast.length > 0 ? `上次同步：${this.localCalLast}` : '等待首次同步')
                    : '带截止日的待办写成全天事件')
                    .fontSize(10)
                    .fontColor($r('app.color.muted'))
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.localCalEnabled })
                  .selectedColor($r('app.color.accent'))
                  .onChange((isOn: boolean) => {
                    this.localCalToggle(isOn);
                  })
              }
              .width('100%')
              .padding({ top: 13, bottom: 13 })

              if (this.localCalEnabled) {
                this.RowDivider()
                Row({ space: 8 }) {
                  this.Chip(this.localCalBusy ? '同步中…' : '立即同步', () => {
                    this.localCalSync(true);
                  }, false)
                  this.Chip('清除事件', () => {
                    this.confirmLocalCalClear();
                  }, true)
                }
                .width('100%')
                .padding({ top: 12, bottom: 12 })
              }
              this.RowDivider()
              Text('带截止日、未完成的任务会以「全天事件」写入系统默认日历账户，完成后自动移除。只操作本应用创建的事件，不会改动你手动添加的日程；首次同步需授予日历读写权限。')
                .fontSize(10)
                .fontColor($r('app.color.muted'))
                .width('100%')
                .padding({ top: 10, bottom: 12 })
            }
            .width('100%')
            .padding({ left: 14, right: 14 })
            .backgroundColor($r('app.color.card'))
            .borderRadius(16)
            .alignItems(HorizontalAlign.Start)

            /* ==================== 日历订阅 ==================== */
            this.GroupTitle('日历订阅（iPhone / Google）')
            Column() {
              Row() {
                Text('同步到日历订阅')
                  .fontSize(14)
                  .fontColor($r('app.color.fg'))
                  .layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.calEnabled })
                  .selectedColor($r('app.color.accent'))
                  .onChange((isOn: boolean) => {
                    this.calToggle(isOn);
                  })
              }
              .width('100%')
              .padding({ top: 6, bottom: 6 })

              if (this.calEnabled) {
                this.RowDivider()
                Column({ space: 8 }) {
                  TextInput({ placeholder: 'Gitee 用户名', text: this.calOwner })
                    .fontSize(12)
                    .fontColor($r('app.color.fg'))
                    .placeholderColor($r('app.color.muted'))
                    .height(38)
                    .width('100%')
                    .backgroundColor($r('app.color.bg'))
                    .borderRadius(10)
                    .padding({ left: 10, right: 10 })
                    .onChange((value: string) => {
                      this.calOwner = value;
                    })
                  TextInput({ placeholder: '仓库名（须为公开仓库）', text: this.calRepo })
                    .fontSize(12)
                    .fontColor($r('app.color.fg'))
                    .placeholderColor($r('app.color.muted'))
                    .height(38)
                    .width('100%')
                    .backgroundColor($r('app.color.bg'))
                    .borderRadius(10)
                    .padding({ left: 10, right: 10 })
                    .onChange((value: string) => {
                      this.calRepo = value;
                    })
                  TextInput({ placeholder: 'Gitee 私人令牌（勾选 projects 权限）', text: this.calToken })
                    .fontSize(12)
                    .fontColor($r('app.color.fg'))
                    .placeholderColor($r('app.color.muted'))
                    .height(38)
                    .width('100%')
                    .backgroundColor($r('app.color.bg'))
                    .borderRadius(10)
                    .padding({ left: 10, right: 10 })
                    .onChange((value: string) => {
                      this.calToken = value;
                    })
                  Row({ space: 8 }) {
                    this.Chip('保存配置', () => {
                      this.calSave();
                    }, false)
                    this.Chip(this.calBusy ? '同步中…' : '立即同步', () => {
                      this.calSyncNow();
                    }, false)
                    if (this.calUrl.length > 0) {
                      this.Chip('复制订阅链接', () => {
                        this.calCopyUrl();
                      }, false)
                    }
                  }
                  .width('100%')

                  if (this.calUrl.length > 0) {
                    Text(this.calUrl)
                      .fontSize(10)
                      .fontColor($r('app.color.muted'))
                      .width('100%')
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  if (this.calLastSync.length > 0) {
                    Text(`上次同步：${this.calLastSync}`)
                      .fontSize(10)
                      .fontColor($r('app.color.muted'))
                      .width('100%')
                  }
                }
                .width('100%')
                .padding({ top: 12, bottom: 12 })
                .alignItems(HorizontalAlign.Start)
              }
              this.RowDivider()
              Text('带截止日的未完成任务会以「全天事件」推送到你的 Gitee 仓库；iPhone 在「日历 → 账户 → 添加订阅日历」粘贴链接即可，订阅约每 30 分钟自动刷新。链接含随机段，仅持有完整地址者可见。')
                .fontSize(10)
                .fontColor($r('app.color.muted'))
                .width('100%')
                .padding({ top: 10, bottom: 12 })
            }
            .width('100%')
            .padding({ left: 14, right: 14 })
            .backgroundColor($r('app.color.card'))
            .borderRadius(16)
            .alignItems(HorizontalAlign.Start)

            /* ==================== 数据清理 ==================== */
            this.GroupTitle('数据清理')
            Column() {
              Row({ space: 10 }) {
                this.Chip('清理已完成', () => {
                  this.confirmClearCompleted();
                }, false)
                this.Chip('清空本账号', () => {
                  this.confirmClearAll();
                }, true)
              }
              .width('100%')
              .padding({ top: 12, bottom: 12 })
            }
            .width('100%')
            .padding({ left: 14, right: 14 })
            .backgroundColor($r('app.color.card'))
            .borderRadius(16)
            .alignItems(HorizontalAlign.Start)

            /* ==================== 关于 ==================== */
            this.GroupTitle('关于')
            Column() {
              /* 折叠头：点按展开 / 收起 */
              Row() {
                Text('象限待办')
                  .fontSize(14)
                  .fontColor($r('app.color.fg'))
                  .layoutWeight(1)
                Text(`v${APP_VERSION}`)
                  .fontSize(12)
                  .fontColor($r('app.color.muted'))
                SymbolGlyph($r('sys.symbol.chevron_down'))
                  .fontSize(13)
                  .fontColor([$r('app.color.muted')])
                  .margin({ left: 6 })
                  .rotate({ angle: this.aboutExpanded ? 180 : 0 })
              }
              .width('100%')
              .padding({ top: 13, bottom: 13 })
              .onClick(() => {
                this.aboutExpanded = !this.aboutExpanded;
              })

              if (this.aboutExpanded) {
                this.RowDivider()

                Row() {
                  Text('应用')
                    .fontSize(14)
                    .fontColor($r('app.color.fg'))
                    .layoutWeight(1)
                  Text('象限待办')
                    .fontSize(12)
                    .fontColor($r('app.color.muted'))
                }
                .width('100%')
                .padding({ top: 13, bottom: 13 })

                this.RowDivider()

                Row() {
                  Text('系统要求')
                    .fontSize(14)
                    .fontColor($r('app.color.fg'))
                    .layoutWeight(1)
                  Text('HarmonyOS 6.0（API 20）+')
                    .fontSize(12)
                    .fontColor($r('app.color.muted'))
                }
                .width('100%')
                .padding({ top: 13, bottom: 13 })

                this.RowDivider()

                Row() {
                  Text('源码')
                    .fontSize(14)
                    .fontColor($r('app.color.fg'))
                    .layoutWeight(1)
                  Text('GitHub · quadrant-todo')
                    .fontSize(12)
                    .fontColor($r('app.color.muted'))
                    .maxLines(1)
                }
                .width('100%')
                .padding({ top: 13, bottom: 13 })

                this.RowDivider()

                Column({ space: 6 }) {
                  Text('一款本地优先的四象限任务管理应用：按「重要 / 紧急」两维把待办放进四个象限，任务默认只存在本机数据库（RDB），可选备份到云端或写入系统日历。')
                    .fontSize(10)
                    .fontColor($r('app.color.muted'))
                  Text('任务与账号均不上传（云备份由你主动开启除外），卸载应用即清除全部本地数据。')
                    .fontSize(10)
                    .fontColor($r('app.color.muted'))
                  Text('源码说明：本应用是开源项目 quadrant-todo（github.com/jailedxiu/quadrant-todo）的 HarmonyOS 移植版，界面与数据层为 ArkTS 重写，遵循原项目开源许可。')
                    .fontSize(10)
                    .fontColor($r('app.color.muted'))
                  Text('免责条款：本应用按「现状」提供，不作任何明示或默示的担保。任务数据保存在本机，请定期使用备份功能；因设备故障、误操作、卸载或第三方服务（华为云 / Gitee）异常导致的数据丢失，开发者不承担任何责任。')
                    .fontSize(10)
                    .fontColor($r('app.color.muted'))
                }
                .width('100%')
                .padding({ top: 12, bottom: 16 })
                .alignItems(HorizontalAlign.Start)
              }
            }
            .width('100%')
            .padding({ left: 14, right: 14 })
            .backgroundColor($r('app.color.card'))
            .borderRadius(16)
            .alignItems(HorizontalAlign.Start)

            Text('')
              .width('100%')
              .height(10)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 18, right: 18, top: 18, bottom: 22 })
      .backgroundColor($r('app.color.bg'))
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      Column() {
        if (this.navTab === 1) {
          this.WeekPage()
        } else {
          // navTab 0（时间轴）与 2（设置抽屉打开时的背景）都显示时间轴
          this.Header()
          if (this.ready) {
            this.Board()
          } else {
            Column() {
              LoadingProgress()
                .width(30)
                .height(30)
                .color($r('app.color.accent'))
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          }
          // B 方案主屏：底部输入行「记下要做的事」+ 四象限归入键，作为新建待办入口
          this.TimelineDock()
        }
        this.BottomNav()
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg'))

      if (this.showEditor) {
        this.FullTaskEditor()
      }

      if (this.showRuler) {
        this.RulerPanel()
      }

      if (this.showDone) {
        this.DonePanel()
      }

      if (this.showSettings) {
        this.SettingsPanel()
      }

      if (!this.agreed) {
        this.AgreementPanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
    // 键盘弹起时移除 BOTTOM 扩展：否则内容被延伸到键盘区域，
    // 抵消 RESIZE 压缩，导致底部归类键落到键盘下方被遮挡。
    .expandSafeArea([SafeAreaType.SYSTEM],
      this.keyboardVisible ? [SafeAreaEdge.TOP] : [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .padding({ top: this.topInset, bottom: this.keyboardVisible ? 0 : this.bottomInset })
  }
}
