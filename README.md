# Plasma Bulk Transfer Tool

A simple, open-source **batch transfer tool** for the Plasma blockchain.  
Supports sending **native XPL** and **ERC-20 tokens** to multiple addresses in one go.  

## ✨ Features
- Send **XPL** and popular ERC-20 tokens (or add custom ERC-20 contract).
- Paste addresses manually or upload a **CSV** (`address,amount`).
- Built-in **fee calculation** (0.10%) – transparent and fair.
- Option to use **atomic mode** (all-or-nothing) or **allow failures with refund**.
- Automatic **chunking** to avoid gas issues.
- Deployed contract is **verified on Plasmascan**.

## 🔗 Links
- **Live app**: [stakeridoo.github.io/PlasmaBulkTransfer](https://stakeridoo.github.io/PlasmaBulkTransfer/)  
- **Contract (verified)**: [0x571452919EE2A638766AC503BFa0522B1887722c](https://plasmascan.to/address/0x571452919EE2A638766AC503BFa0522B1887722c)  

## 📦 Usage
1. Open the [Live App](https://stakeridoo.github.io/PlasmaBulkTransfer/).
2. Connect your wallet (MetaMask or compatible).
3. Select token (XPL, common ERC-20, or custom contract).
4. Add addresses manually or upload CSV with format:  
address,amount
```csv
0x56e08bABb8bf928bD8571D2a2a78235ae57AE5Bd,1.25
0xf96684AC970046F10Ce135Ffef778758A8a16846,0.75
0xf96684AC970046F10Ce135Ffef778758A8a16846,2.00
```
5. Click **Estimate & Validate**, then **Send**.

## 🛠 Planned Improvements
- Privacy mode with **stealth addresses**.
- UI/UX polish & analytics.
- Support for more Plasma ecosystem tokens.

## 🤝 Feedback
Feedback, issues, or feature requests are very welcome!  
Please open an issue

---

Built with ❤️ by [Stakeridoo](https://x.com/stakeridoo)
