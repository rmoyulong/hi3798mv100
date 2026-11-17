海思Hi3798MV100(九联-UNT400B) 内核和模块、DTB编译 <br>
Open-source software/firmware for HiSilicon Hi3716 / Hi3796 / Hi3798 devices<br>
[![build](https://img.shields.io/github/actions/workflow/status/rmoyulong/hi3798mv100/hisi.yml)](https://github.com/rmoyulong/hi3798mv100/actions/workflows/hisi.yml) [![downloads](https://img.shields.io/github/downloads/rmoyulong/hi3798mv100/total)](https://github.com/rmoyulong/hi3798mv100/releases) [![downloads@latest](https://img.shields.io/github/downloads/rmoyulong/hi3798mv100/latest/total)](https://github.com/rmoyulong/hi3798mv100/releases/latest)<br>

本仓库编译的是九联-UNT400B，其他板子的参数请按照实际情况编写！

- \`linux仓库\`： https://github.com/torvalds/linux.git <br>
- \`海思的补丁仓库\`： https://github.com/histb-mainline/patches.git <br>

补丁库是一整条有序序列，缺一个后面全冲突
补丁都放在根目录，靠 000 到 955 的文件名序号决定顺序，后一个的上下文建立在前一个的改动之上。
因此只能整体按序应用，不能用 grep 挑；筛掉任意一个，它后面的补丁就会找不到上下文而失败。
脚本现在的逻辑是「有 series 文件就按 series 顺序，没有就按序号全量应用」，两处都‌没有芯片名筛选‌，这是设计如此。
芯片区分发生在 config 与设备树，不在打补丁环节
补丁库里属于 Hi3716CV200、Hi3798MV200 的那些改动是共用序列的一部分，必须一起打进去；不在 .config 里选中对应选项，就不会编进内核。
真正决定成品面向哪颗芯片的是 .config 的机器配置和构建时选用的设备树，而不是补丁清单的筛选结果。
换句话说，Hi3798MV100 的适配是靠补丁 + config + DTS 三者配合生效，单靠筛补丁名做不到，反而会破坏序列。
想确认 MV100 补丁已生效，看成品最直接
你这次 Release 里的 ‌hi3798mv100-ec6108v9c.dtb（17.7 KB）‌ 就是 MV100 板级补丁应用成功后才可能生成的文件，加上 zImage 和模块一起，说明这套补丁确实落到了成品上。
想收紧范围，唯一值得排除的是 900-955 那批作者本地 bring-up / bench 补丁，其余都属正确序列，不要按芯片名删。

| 用途 | 现在强制的符号 |
| --- | --- |
| eMMC 驱动 | MMC_DW、MMC_DW_PLTFM、MMC_DW_HI3798CV200 |
| 块设备与根文件系统 | MMC、MMC_BLOCK、EXT4_FS、JBD2、FS_MBCACHE |
| 控制台串口 | SERIAL_AMBA_PL011、SERIAL_AMBA_PL011_CONSOLE |
| 启动设备树 | ARM_APPENDED_DTB、ARM_ATAG_DTB_COMPAT、USE_OF |

‌新内核已在实机上跑通‌：UNT400B 现在运行的是主线 ‌7.4.0-rc2‌ 加 ‌129 个 histb 补丁‌编出的镜像，整条构建与刷写链路都已验证正确。

这次是四处关键点对齐的结果
这套补丁面向 Hi3798MV100 家族，源码基线改用补丁库自述的 ‌7.4-rc2 / fd9230005e85‌，不再套用别的版本。
eMMC 真正生效的是 ‌CONFIG_MMC_DW_HI3798CV200‌；我先前写的 MMC_HISI_SDHCI 内核里并不存在，那就是那次报错的唯一原因。
uImage 仍是 ‌加载/入口 0x02000000、-C none‌，设备树追加在 zImage 末尾。
根分区继续由 bootargs 分区传 ‌root=/dev/mmcblk0p9‌，内核自身 cmdline 留空，没有硬写

往后复用的两条路径
再想升版本：把 PATCHES_BASE_SHA、PATCHES_KERNEL_VERSION 跟着补丁库 baseline 一起改，其余步骤照跑即可。
哪天要回原厂：dd if=<备份目录>/kernel.bin of=/dev/mmcblk0p6 bs=1M conv=fsync，模块目录改名换回，还是同一套回滚动作。
主线内核不识别 mmz=ddr,0,0,48M，海思私有的 VPU/GPU 硬解不会启用；日常使用不受影响，但视频硬解一类功能可能缺失，需要时得靠这套补丁后续继续补齐。

刷机已经成功，内核、eMMC、根文件系统全部正常。日志里唯一的异常是系统想把 ‌p8（backup 分区）当作交换分区激活、激活失败‌，这是用户空间镜像里的配置残留，与本次新内核无关，不影响启动和使用。

| 验证项 | 结果 | 判定 |
| --- | --- | --- |
| 内核启动 | 7.4.0-rc2+，129 个 histb 补丁 | 通过 |
| eMMC | mmcblk0 7.28 GiB，p1–p9 齐备 | 通过 |
| 根文件系统 | p9 挂载、可读写、无日志恢复告警 | 通过 |
| swap | 仅 zram0，单元 masked、fstab 两行已注释 | 通过 |
| eth0 MAC | 固定 9e:fa:ea:68:2f:a0，重启后不变 | 通过 |
| 网口吞吐 | 正反向均 93.4–93.7 Mbits/sec，Retr 0 | 满速 |
| USB 存储 | TOSHIBA 盘识别，顺序写 23.4 MB/s | 通过 |
| 无线 | wlx20f54385e08d 接口存在，驱动就绪 | 通过 |