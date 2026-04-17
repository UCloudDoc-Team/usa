# v2 - Skill Auditor - Agent 技能安全审计工具

---

## 背景

随着大语言模型（LLM）与 AI 代理（Agent）技术在企业中的快速落地，**Hermes-Agent** 作为核心 AI 代理平台，通过可扩展的"技能（Skill）"机制为用户提供丰富的自动化能力。然而，这种开放式的技能生态也带来了新的安全挑战：

- **供应链攻击风险**：第三方技能可能包含恶意代码，在安装或更新时被植入后门、数据窃取逻辑或提权操作，传统的软件供应链安全手段难以覆盖 AI Agent 技能这一新型攻击面。
- **技能变更不可控**：技能在运行周期内可能被静默篡改，导致原本安全的技能行为发生异变，而现有机制缺乏对技能文件完整性的持续监控与变更追溯能力。
- **缺乏统一审计标准**：AI Agent 技能涉及动态代码执行、文件操作、网络通信等敏感行为，行业尚无成熟的安全审计规范，企业在合规审计中面临无据可依的困境。
- **人工审查效率低**：技能数量持续增长，纯人工代码审查成本高、覆盖率低，无法满足快速迭代环境下的安全需求。

![image](assets/resources/zQC1dxxNaQyl4Tgw7nDmUU-PPQWGo-FNW4C4zOH9IkU.png)

为应对上述挑战，我们设计并实现了 **Skill Auditor** —— 一套专为 Hermes-Agent 技能生态打造的自动化安全审计系统。它基于**零信任**原则，结合静态威胁扫描、双层语义分析和完整性基线管理，在技能安装、更新和运行的全生命周期提供自动化、可验证的安全保障，帮助企业在享受 AI Agent 能力扩展的同时，有效管控安全风险。

---

## 工作流程

 Skill Auditor 的核心工作流由**规则扫描、语义分析、基线对比、日志审计、风险评级** 五大模块构成。系统以**基线比对机制** 为触发点，精准识别指定时间窗口内发生变更的 Skills。随后，结合多维度的静态分析与语义分析进行综合研判，最终输出包含严重、高、中、低四个等级的**量化风险评估报告**

这一流程形成了一个闭环的安全防护体系，通过层层把关，保障系统安全稳定运行。



![image](assets/resources/7A1NjYOTGnvbJcYDwFXIgM68ze3P-ju_gXrZNcY1kw4.png)

安全设计原则

| **原则**           | **说明**                              |
|--------------------|---------------------------------------|
| **零信任**         | 不假设任何技能可信，所有技能必须审计   |
| **本地优先**       | 审计过程完全本地化，不依赖外部服务     |
| **透明可验证**     | 所有结果以 NDJSON 记录，可供第三方验证 |
| **不执行未知代码** | 纯静态分析，审计过程绝不执行被审计代码 |



---

## 适用场景

Skill Auditor 适用于企业安全团队、个人开发者和 AI 代理用户，帮助：

- **预防供应链攻击**：在技能安装前进行安全扫描
- **合规审计**：满足企业安全合规要求
- **持续监控**：检测技能变更并推送告警
- **风险评估**：四级风险评级（Low/Medium/High/Extreme），辅助决策

![image](assets/resources/uYgEBzkIIAjxNKRoSzrmui2tPEB-ge4hhxGczFxZ-1k.png)

通过 Skill Auditor，用户可以获得企业级的安全保障，同时保持 OpenClaw 生态系统的开放性和灵活性。

---

## 核心安全能力

采用序列图形式，展示 5 个阶段：

1. **触发审计**：用户执行命令或文件变更事件
2. **文件监控与 Diff 分析**：扫描目录、对比基线、git diff 获取变更
3. **并行安全检查**：SHA-256 完整性校验 + LLM 语义分析并行执行
4. **报告生成与日志记录**：生成安全评级、格式化证据、写入 NDJSON 日志
5. **输出结果**：返回审计摘要（安全/风险告警）

![image](assets/resources/gQ2GQu8-TUJ0Dt-1J6thQZ51Dpy0nNrRPM43AvGKn_0.png)



### 1\. 静态威胁扫描

基于大量专业安全规则检测：

- 动态代码执行（eval/exec/os.system）
- 危险文件系统操作
- 网络数据泄露风险
- 持久化/提权/容器逃逸
- 加密货币挖矿行为



### 2\. 语义分析

在代码审查过程中，存在脚本层快速初筛和Agent层深度分析两种方式。脚本层快速初筛通过对源代码进行正则匹配、危险函数识别、关键词评分等操作，能迅速对代码进行初步评估。而Agent层深度分析则更为细致，运用LLM语义理解、混淆检测、间接调用分析以及上下文感知评分等技术，深入挖掘代码潜在风险。

 为平衡安全性与实用性，系统支持灵活的规则配置，该技能还具备降级网络规则、忽略动态执行、放宽信息收集等策略，可根据技能类型自动调整规则严格度，避免有 CLI 等工具因与系统交互而被错杀。

![image](assets/resources/IZG9F_oZiHnR_PFrHcW3NU8Iih-kyqZEo1otrVL5vAY.png)

**创新点**: 上下文感知评分，根据技能类型自动调整规则严格度，降低误报率。



### 3\. 完整性校验与基线管理

完整性校验与基线管理流程涉及：SHA - 256计算、基线比对、变更审计、Git快照等环节。先对Skills文件树计算Hash值，再进行基线比对。若比对结果显示已审计且 Hash 值无变化，可跳过告警；若文件发生变更，则触发审计。审计后会进行Git快照存档，并生成Diff报告，可供人工审核复验。

![image](assets/resources/3w4thYtHC1sFG7jwzA0UjyPjnzc3jg-LoWyZ-f9zq_s.png)

- **SHA-256 Tree Hash** \- 整棵树哈希，任何文件变更自动打破审批
- **基线审批机制** \- 已验证技能不再重复告警，减少噪音
- **Git 快照追溯** \- 完整的版本历史和代码变更对比



### 4\. 安全日志与证据留存

- **NDJSON 追加式日志** \- 不可篡改，便于事后审计
- **完整证据链** \- 代码片段、风险模式、域名信息全记录
- **本地化存储** \- `~/.hermes/skills-audit/` 用户完全控制

---

## 系统资源占用测试

**测试环境**: 2 核 4G

| **指标** | **静默状态** | **运行状态** | **增量** |
|----------|--------------|--------------|----------|
| CPU 平均 | 10.20%       | 22.79%       | +12.59%  |
| 内存平均 | 48.95%       | 59.01%       | +10.06%  |

**结论**: 轻量级设计，对系统性能影响很小。



## 安全效果验证

**测试样本**: 80 个（白样本 50 个，黑样本 30 个）

| **样本类型** | **High** | **Medium** | **Low** | **准确率** |
|--------------|----------|------------|---------|------------|
| 白样本       | 1        | 27         | 22      | **98%**    |
| 黑样本       | 11       | 17         | 2       | **93.33%** |

**误报率**: 2% | **漏报率**: 6.67%

---

## 工具使用

### 快速开始

> 下载链接： [https://github.com/ucloud-security/skills-auditor](https://github.com/ucloud-security/skills-auditor)

目录简介：

- **技术文档**: `~/.hermes/skills/skills-auditor/SKILL.md`
- **审计日志**: `~/.hermes/skills-audit/logs.ndjson`
- **Git 快照**: `~/.hermes/skills-audit/snapshots/`

使用说明见  [https://github.com/ucloud-security/skills-auditor](https://github.com/ucloud-security/skills-auditor)

### 告警通知案例

```plain
【Skills 监控提醒】
检测到 skills 目录发生变更

【⚠️ 高风险技能】
  • red-teaming
  • productivity
  • leisure: +4 行变更

【其他变更】
  • 🟢 devops (新增)

📁 路径：/Users/user/.hermes/skills
🕒 时间：2026-04-16T07:55:11Z (CST)
🧾 审计日志：~/.hermes/skills-audit/logs.ndjson
⚠️ 敏感信息警告：完整 diff 请在本机查看
```
 
![image](assets/resources/j4Yhab8mT3iPi205wIcx4JmnRixvdDOdSkI4PpA5Q8w.png)





##  其他

 上述为  Hermes-Agent  版本的安全审计工具  skills-auditor，同样我们也有  OpenClaw  版的  skills-auditor，欢迎前去体验。

 Hermes-Agent  Skill  Auditor [GitHub - ucloud-security/skills-auditor: hermes-agent skill · GitHub](https://github.com/ucloud-security/skills-auditor)

 OpenClaw  Skill  Auditor  [Skill Auditor — ClawHub](https://clawhub.ai/ucloud-security/skills-auditor)
