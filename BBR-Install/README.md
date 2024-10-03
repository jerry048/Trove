
# BBR 拥塞控制算法安装脚本

## 简介

欢迎使用 **BBR 拥塞控制算法安装脚本**！本脚本旨在帮助用户轻松在 Ubuntu 和 Debian 系统上安装和配置不同版本的 BBR 拥塞控制算法（如 bbrx、bbrw、attack），以优化网络性能。

## 前提条件

- **操作系统**：Ubuntu 22.04 / 24.04 或 Debian 11 / 12
- **内核版本**：5.10.0、5.15.0、6.1.0 或 6.8.0
- **权限**：需要以 root 用户或具有 sudo 权限的用户运行脚本

## 安装步骤

1. 使用此脚本前，请确保您具有root权限。脚本的使用方式如下：

  ```bash
  bash <(wget -qO- https://raw.githubusercontent.com/jerry048/Trove/refs/heads/main/BBR-Install/BBRInstall.sh)
  ```

2. 选择要安装的 BBR 拥塞控制算法（`bbrx`、`bbrw`、`attack`）
3. 如果系统缺少对应内核版本的头文件，脚本将自动安装新内核并提示重启。
4. 安装完成后，无需重启即可生效。如果遇到需要重新启动的情况，请根据提示操作。

## BBR 版本简介
### BBRw
当网络延迟增加时，传统BBR会根据提供的代码做出以下反应：

1. **维护最小RTT估计：**
   - BBR跟踪在一个滑动窗口（10秒，`bbr_min_rtt_win_sec`）内观察到的最小RTT延迟（`min_rtt_us`）。
   - 只有当新的RTT样本小于当前的`min_rtt_us`或者最小RTT过滤窗口过期时，才会更新`min_rtt_us`。 
   - 如果最小RTT过滤窗口过期（即在过去10秒内没有新的最小RTT），BBR会转换到`BBR_PROBE_RTT` 模式来测试RTT提升是纯粹的传播延迟还是由于队列积压引起的延时。

   ```c
   static void bbr_update_min_rtt(struct sock *sk, const struct rate_sample *rs)
   {
       struct tcp_sock *tp = tcp_sk(sk);
       struct bbr *bbr = inet_csk_ca(sk);
       bool filter_expired;

       // 检查最小RTT窗口是否已过期（超过10秒）
       filter_expired = after(tcp_jiffies32,
                      bbr->min_rtt_stamp + bbr_min_rtt_win_sec * HZ);

       // 如果观察到更小的RTT或过滤器已过期且没有ACK延迟，则更新最小RTT
       if (rs->rtt_us >= 0 &&
           (rs->rtt_us < bbr->min_rtt_us ||
            (filter_expired && !rs->is_ack_delayed))) {
           bbr->min_rtt_us = rs->rtt_us;
           bbr->min_rtt_stamp = tcp_jiffies32;
       }
       ...
   }
   ```

2. **进入PROBE_RTT模式：**
   - 在`BBR_PROBE_RTT`模式下，BBR将其拥塞窗口减少到最小值，减速至~6Kbps 左右（通常为4个数据包，`bbr_cwnd_min_target`），至少维持200毫秒（`bbr_probe_rtt_mode_ms`）。
   - 这一过程促使别人的流分享你空出来的带宽，避免了单个流独占大量带宽或形成长队列的情况。
   ```c
   if (bbr_probe_rtt_mode_ms > 0 && filter_expired &&
       !bbr->idle_restart && bbr->mode != BBR_PROBE_RTT) {
       bbr->mode = BBR_PROBE_RTT;  // 进入PROBE_RTT模式
       bbr_save_cwnd(sk);  // 保存当前cwnd以便稍后恢复
       bbr->probe_rtt_done_stamp = 0;
   }
   ```

### BBRw 对比原版BBR阉割了这个行为

### **1. 追踪最大RTT

- **跟踪最大RTT：** 修改后的BBR不再追踪最小RTT而是在观察到更大的RTT时更新`min_rtt_us`变量。 如果在10秒内没有发现延迟提升，我们可以理解为没有队列积压并进入Probe RTT模式更激进的抢带宽。

### **2. 在Probe RTT模式下增加了节奏和拥塞窗口增益**

- **Probe RTT模式下更高的增益：** 修改后的BBR在`BBR_PROBE_RTT`模式下将`pacing_gain`和`cwnd_gain`均设置为`bbr_high_gain`，算法持续以激进的方式发送数据，即使在原始BBR会降低发送速率的阶段，也可能保持高吞吐量。
- **使用先前的拥塞窗口：** 修改后的BBR在进入`BBR_PROBE_RTT`模式时使用不会减速到固定的最小值`bbr_cwnd_min_target`。这意味着在Probe RTT期间并不会减速。

### **总体性能影响**

修改后的BBR算法通过在RTT测量和探测阶段调整节奏和拥塞窗口增益，变得更加激进。算法对拥塞信号（如RTT增加）的敏感性降低。特别是在共享或容量有限的网络中，激进的行为可能导致带宽共享不公平，可能使其他连接受到饥饿。

---
### Attack
#### 在BBRw的前提下， Attack做了更激进的修改

### 主要修改点：

1. **忽略数据包丢失：**
   - **禁用数据包保守原则：** 修改后的BBR移除了数据包保守原则。在函数 `bbr_set_cwnd_to_recover_or_restore()` 中，算法不再因数据包丢失而减少拥塞窗口（`cwnd`）。相反，它会维持或增加 `cwnd`，无论网络状况如何。
   - **丢包时不调整状态：** 函数 `bbr_set_state()` 实际上被禁用，这意味着算法在进入丢包状态（`TCP_CA_Loss`）时不会调整其行为。

2. **禁用长期带宽采样：**
   - **不进行警察检测：** 函数 `bbr_lt_bw_sampling()` 被禁用，这意味着算法不再执行长期带宽采样以检测和适应网络警察（QoS）。这种遗漏阻止了算法根据持续的拥塞信号调整其行为。

5. **简化周期阶段转换：**
   - **在周期决策中忽略丢包：** 在决定是否推进到下一个周期阶段（`bbr_is_next_cycle_phase()`）时，修改后的BBR忽略了数据包丢失作为一个因素。原始算法将丢包视为网络无法处理当前发送速率的指示。

### 结论：

理论上修改后的BBR算法通过忽略关键的拥塞信号（如数据包丢失和RTT增加）优先考虑吞吐量，而非网络友好性。在某些条件下可能实现更高的数据传输速率，但是会增加延迟、以及更高的数据包丢失率。
# ！！ 注意：在实际网络环境中，因为QoS等各种因素，反而很有可能比原版BBR的表现更差。
### BBRx

### **1. 更加积极的带宽探测**

-   **增加的 `bbr_high_gain` 和调整后的 Pacing 增益**：用于 `BBR_STARTUP` 阶段的 `bbr_high_gain` 值显著增加，并且 `BBR_PROBE_BW` 阶段的 pacing 增益被调整得更加积极。这意味着 bbrx 更快速地提升其发送速率以探测可用带宽。
- **调整后的 `bbr_full_bw_thresh` 和 `bbr_full_bw_cnt`**：将认为带宽管道“满”的带宽增加阈值从 25% 降低到 5%，并将无需显著带宽增长即可退出启动阶段的轮次数从 3 增加到 10。
-   **将 `bbr_pacing_margin_percent` 从 1% 增加到 5%**：pacing 速率设置为估计带宽以上 5%，而非以下1%。

### **2. 更大的拥塞窗口**

-   **翻倍的 `bbr_cwnd_gain` 和增加的 `bbr_cwnd_min_target`**：用于计算拥塞窗口的增益翻倍，且最小拥塞窗口从 4 个数据包增加到 200 个数据包。

### **3. 对 RTT 变化响应减弱**

-   **将 `bbr_min_rtt_win_sec` 从 10 秒增加到 10 分钟**：最小 RTT 估计的更新频率降低。

### **4. 调整后的 ACK 聚合处理**

-   **增加的 `bbr_extra_acked_gain` 和窗口大小**：应用于额外 ACK 已确认数据的增益增加，并且测量该数据的窗口扩大。

### **总体性能影响**

修改后的 BBR 算法采用了更积极的带宽利用策略，适用于需要最大吞吐量且网络能够处理增加负载而不显著拥塞的环境。然而，在对延迟和拥塞敏感的网络中，这些修改可能导致性能下降。务必在预期的部署场景中彻底测试 BBRx，以确保其优势超过潜在的缺点，并根据需要调整参数，以在吞吐量、网络稳定性和公平性之间取得平衡。



## 常见问题

### 脚本运行失败

- **权限问题**：请确保以 root 用户或使用 `sudo` 运行脚本。
- **不支持的操作系统或内核版本**：请检查你的系统是否符合支持列表。
- **网络问题**：确保你的服务器可以访问 GitHub 和其他必要的下载源。

### 模块未加载

- **检查内核版本**：确保内核版本符合脚本支持的版本。
- **手动加载模块**：

  ```bash
  sudo modprobe tcp_你的算法名称
  ```

- **查看日志**：检查 `/var/log/syslog` 或使用 `dmesg` 查看详细错误信息。
