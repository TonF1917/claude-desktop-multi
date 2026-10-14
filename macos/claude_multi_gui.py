"""Tk manager window in the Anthropic look (ivory / slate / clay, serif type). Standard library only; works on macOS and Windows."""
import math, tkinter as tk
from tkinter import colorchooser, messagebox, ttk

IVORY, SLATE, CLAY, CLAY_D, OAT, CLOUD, MID, GRAY, SEL = '#FAF9F5', '#141413', '#D97757', '#C6613F', '#E8E6DC', '#F0EEE6', '#5E5D59', '#87867F', '#F6E7DF'
SERIF = 'Georgia'


def hsv_hex(p):
    import colorsys
    r, g, b = colorsys.hsv_to_rgb((p['hue'] % 360) / 360, p['sat'], (p['vMin'] + p['vMax']) / 2)
    return '#%02X%02X%02X' % (int(r * 255), int(g * 255), int(b * 255))


class Btn(tk.Canvas):                       # rounded button drawn by hand (native Aqua buttons ignore colours)
    def __init__(self, master, text, command, primary=False, width=280, height=40):
        super().__init__(master, width=width, height=height, bg='white', highlightthickness=0, cursor='hand2')
        self.text, self.cmd, self.primary, self.w, self.h = text, command, primary, width, height
        self.bind('<Button-1>', lambda e: self.cmd()); self.bind('<Enter>', lambda e: self.draw(True)); self.bind('<Leave>', lambda e: self.draw(False)); self.draw(False)

    def draw(self, hover):
        self.delete('all'); r = 10; fill = (CLAY_D if hover else CLAY) if self.primary else (CLOUD if hover else 'white'); line = CLAY if self.primary else OAT
        pts = [r, 1, self.w - r, 1, self.w - 1, 1, self.w - 1, r, self.w - 1, self.h - r, self.w - 1, self.h - 1, self.w - r, self.h - 1, r, self.h - 1, 1, self.h - 1, 1, self.h - r, 1, r, 1, 1]
        self.create_polygon(pts, smooth=True, fill=fill, outline=line, width=2)
        self.create_text(self.w // 2, self.h // 2, text=self.text, fill='white' if self.primary else SLATE, font=(SERIF, 11))


def card(master, **kw):
    return tk.Frame(master, bg='white', highlightbackground=OAT, highlightthickness=2, **kw)


def run(core):
    cfg = core.read_config(); pal = core.palettes(); providers = core.cc_providers()
    zh = cfg['settings'].get('language') == 'zh'
    L = lambda a, b: a if zh else b
    root = tk.Tk(); root.title(L('Claude 多窗口管理器', 'Claude Multi-Window Manager')); root.configure(bg=IVORY); root.geometry('1180x800'); root.resizable(False, False)

    # header
    head = tk.Canvas(root, width=70, height=70, bg=IVORY, highlightthickness=0); head.place(x=24, y=14)
    for k in range(12):
        a = k * math.pi / 6; r2 = 17 if k % 2 else 21
        head.create_line(35 + math.cos(a) * 6, 35 + math.sin(a) * 6, 35 + math.cos(a) * r2, 35 + math.sin(a) * r2, fill=CLAY, width=3, capstyle='round')
    tk.Label(root, text=L('Claude 多窗口管理器', 'Multiple windows, different APIs'), bg=IVORY, fg=SLATE, font=(SERIF, 24, 'bold')).place(x=88, y=10)
    tk.Label(root, text=L('官方订阅与第三方 API 同时运行,每个窗口独立图标', 'Official subscription and third-party APIs side by side, one icon each'), bg=IVORY, fg=MID, font=(SERIF, 11)).place(x=90, y=60)
    def switch_lang():
        c = core.read_config(); c['settings']['language'] = 'en' if zh else 'zh'; core.save_config(c); root.destroy(); run(core)
    tk.Button(root, text='中文' if not zh else 'English', command=switch_lang, font=(SERIF, 10)).place(x=1090, y=22)

    # windows table
    left = card(root); left.place(x=24, y=102, width=800, height=430)
    tk.Label(left, text=L('窗口', 'Windows'), bg='white', fg=SLATE, font=(SERIF, 13, 'bold')).place(x=18, y=10)
    st = ttk.Style(); st.theme_use('clam')
    st.configure('A.Treeview', background='white', fieldbackground='white', foreground=SLATE, rowheight=42, borderwidth=0, font=(SERIF, 11))
    st.configure('A.Treeview.Heading', background='white', foreground=GRAY, relief='flat', font=(SERIF, 10)); st.map('A.Treeview', background=[('selected', SEL)], foreground=[('selected', SLATE)])
    cols = ('name', 'id', 'provider', 'palette', 'status')
    tv = ttk.Treeview(left, columns=cols, show='headings', style='A.Treeview', selectmode='browse')
    for c, t, w in (('name', L('名称', 'Name'), 170), ('id', 'ID', 80), ('provider', L('接口 / 供应商 (点击选择)', 'API / provider (click)'), 300), ('palette', L('配色 (点击)', 'Colour (click)'), 150), ('status', L('状态', 'Status'), 70)):
        tv.heading(c, text=t); tv.column(c, width=w, anchor='w')
    tv.place(x=14, y=48, width=772, height=370)
    prov_text = {'__official': L('官方订阅', 'Official subscription'), '': L('跟随 cc-switch 当前选择', 'Follow cc-switch selection')}
    for p in providers:
        fmt = p['meta'].get('apiFormat'); prov_text[p['id']] = p['name'] + (L('  (需经网关)', '  (needs the gateway)') if fmt and fmt != 'anthropic' else L('  (直连上游)', '  (direct)'))
    rows = {i['id']: dict(i) for i in cfg['instances']}

    def refresh():
        tv.delete(*tv.get_children())
        for iid, i in rows.items():
            pv = '__official' if i['kind'] == 'official' else (i.get('provider') if i.get('provider') in prov_text else '')
            run_ = ''
            try:
                if core.IS_MAC: run_ = L('运行中', 'running') if core.running(i) else ''
            except Exception: pass
            tv.insert('', 'end', iid=iid, values=(i['name'], iid, prov_text[pv], i.get('palette', ''), run_))
        sel_preview()
    right = card(root); right.place(x=844, y=102, width=316, height=430)
    prev = tk.Canvas(right, width=96, height=96, bg='white', highlightthickness=0)

    def sel_preview(_=None):
        s = tv.selection()
        if not s: return
        i = rows[s[0]]; spec = i.get('palette', 'official')
        color = CLAY if spec == 'official' else (hsv_hex(core.resolve_palette(spec, pal)))
        prev.delete('all'); prev.create_rectangle(4, 4, 92, 92, fill=color, outline=color, width=2)
        for k in range(12):
            a = k * math.pi / 6; r2 = 30 if k % 2 else 38
            prev.create_line(48 + math.cos(a) * 9, 48 + math.sin(a) * 9, 48 + math.cos(a) * r2, 48 + math.sin(a) * r2, fill='white', width=4, capstyle='round')
    tv.bind('<<TreeviewSelect>>', sel_preview)

    def on_click(e):
        if tv.identify_region(e.x, e.y) != 'cell': return
        iid = tv.identify_row(e.y); col = tv.identify_column(e.x); i = rows.get(iid)
        if not i or i['kind'] == 'official': return
        m = tk.Menu(root, tearoff=0, font=(SERIF, 10))
        if col == '#3':
            for pid, txt in prov_text.items():
                if pid == '__official': continue
                m.add_command(label=txt, command=lambda pid=pid: (i.__setitem__('provider', pid) if pid else i.pop('provider', None), refresh()))
        elif col == '#4':
            for n in pal:
                m.add_command(label=n, command=lambda n=n: (i.__setitem__('palette', n), refresh()))
            def custom():
                c = colorchooser.askcolor()[1]
                if c: i['palette'] = c.upper(); refresh()
            m.add_separator(); m.add_command(label=L('自定义颜色…', 'Custom colour...'), command=custom)
        else: return
        m.tk_popup(e.x_root, e.y_root)
    tv.bind('<Button-1>', on_click, add='+')

    # actions card
    prev.place(x=18, y=18); tk.Label(right, text=L('图标预览', 'Icon preview'), bg='white', fg=SLATE, font=(SERIF, 13, 'bold')).place(x=126, y=22)
    tk.Label(right, text=L('Dock 与桌面', 'Dock and desktop'), bg='white', fg=GRAY, font=(SERIF, 10)).place(x=126, y=52)
    n_add = tk.Spinbox(right, from_=1, to=20, width=3, font=(SERIF, 11)); n_add.place(x=18, y=138)
    def save():
        c = core.read_config(); c['instances'] = list(rows.values()); c['settings'].update(syncSessions=v_sync.get(), liveRefresh=v_live.get(), refreshOfficial=v_off.get()); core.save_config(c)
    def add():
        for _ in range(int(n_add.get())):
            n = 2
            while f'x{n}' in rows: n += 1
            used = {i.get('palette') for i in rows.values()}; p = next((x for x in pal if x not in used), list(pal)[n % len(pal)])
            rows[f'x{n}'] = dict(id=f'x{n}', name=f'Claude 3P {n}', kind='cc-switch', palette=p)
        refresh()
    def remove():
        s = tv.selection()
        if s and rows[s[0]]['kind'] != 'official': rows.pop(s[0]); refresh()
        elif s: messagebox.showinfo('', L('官方窗口不能删除。', 'The official window cannot be removed.'))
    def apply():
        save()
        if core.IS_MAC: core.cmd_install(type('A', (), {'force': False})())
        messagebox.showinfo('', L('已应用。', 'Applied.'))
    def launch():
        s = tv.selection()
        if s: save(); core.launch(rows[s[0]])
    Btn(right, L('添加窗口', 'Add windows'), add, width=200).place(x=88, y=132)
    Btn(right, L('删除所选', 'Remove selected'), remove, width=280).place(x=18, y=186)
    Btn(right, L('应用更改', 'Apply changes'), apply, width=280).place(x=18, y=236)
    Btn(right, L('启动所选', 'Launch selected'), launch, primary=True, width=280).place(x=18, y=296)
    Btn(right, L('立即同步会话', 'Sync sessions now'), lambda: messagebox.showinfo('', str(core.sync_sessions(core.read_config(), {}))), width=280).place(x=18, y=360)

    # behaviour card
    bot = card(root); bot.place(x=24, y=552, width=1136, height=220)
    tk.Label(bot, text=L('同步与行为', 'Sync and behaviour'), bg='white', fg=SLATE, font=(SERIF, 13, 'bold')).place(x=18, y=10)
    v_sync, v_live, v_off = tk.BooleanVar(value=cfg['settings']['syncSessions']), tk.BooleanVar(value=cfg['settings']['liveRefresh']), tk.BooleanVar(value=cfg['settings']['refreshOfficial'])
    for k, (v, t) in enumerate(((v_sync, L('在各窗口间同步会话(后台)', 'Sync sessions across windows (background)')),
                                (v_live, L('实时刷新:空闲且不在前台的窗口会在后台静默重启以载入新会话', 'Live refresh: idle, unfocused windows restart silently to load new sessions')),
                                (v_off, L('同时对官方窗口启用实时刷新(默认关闭)', 'Also live-refresh the official window (off by default)')))):
        tk.Checkbutton(bot, text=t, variable=v, bg='white', fg=SLATE, activebackground='white', font=(SERIF, 11), anchor='w').place(x=14, y=44 + k * 34)
    tk.Label(bot, text=L('macOS 版为实验性:固定/星标同步与 claude:// 路由暂未移植。', 'macOS port is experimental: pin sync and claude:// routing are not ported yet.'), bg='white', fg=GRAY, font=(SERIF, 10)).place(x=18, y=170)
    refresh()
    if tv.get_children(): tv.selection_set(tv.get_children()[0])
    root.mainloop()
