package dev.local.adbtype.mobile.core

import java.util.Locale
import kotlin.random.Random

/**
 * 6 位配对码：本机生成并显示，对方在配对弹窗里输入。
 */
object PairingCode {

    /** 生成 6 位数字码（含前导 0），与 macOS 端的 "%06d" 一致。 */
    fun generate(random: Random = Random.Default): String =
        String.format(Locale.ROOT, "%06d", random.nextInt(1_000_000))

    /** 校验用户输入：恰好 6 位数字，允许首尾空白。 */
    fun normalize(input: String?): String? {
        val trimmed = input?.trim() ?: return null
        if (trimmed.length != 6) return null
        if (!trimmed.all { it in '0'..'9' }) return null
        return trimmed
    }

    /**
     * 比较 hello 里携带的 code 与本机当前配对码。
     * §4.3：code 去掉空白后必须与本机当前 6 位配对码完全相等。
     */
    fun matches(input: String?, expected: String): Boolean {
        val trimmed = input?.trim() ?: return false
        return trimmed.isNotEmpty() && trimmed == expected.trim()
    }
}

/** 服务端对 hello 的处理结论。 */
sealed class HelloDecision {

    /** 允许继续：alreadyPaired 为 false 表示本次是「配对码正确后首次配对」，需要持久化对方 id。 */
    data class Accept(
        val peerId: String,
        val peerName: String,
        val alreadyPaired: Boolean,
    ) : HelloDecision()

    /** 没有带码或码不对：回复 pair_required，并在界面上提示「对方正在请求配对」。 */
    data class NeedsPairing(val peerId: String, val peerName: String) : HelloDecision()

    /** 报文本身非法：回 error 后关闭。 */
    data class Reject(val message: String) : HelloDecision()
}

object PairingPolicy {

    /**
     * 服务端处理 hello（§4.3）：
     * 1. 校验 app / id / name，id 不能等于本机 id；
     * 2. 已在已配对集合 -> hello_ok；
     * 3. 未配对：code 去空白后必须等于本机当前码 -> 记录配对并 hello_ok，否则 pair_required。
     */
    fun evaluateHello(
        hello: Map<String, Any?>?,
        selfId: String,
        currentCode: String,
        pairedPeerIds: Set<String>,
    ): HelloDecision {
        if (hello == null) return HelloDecision.Reject(LanProtocol.MSG_INVALID_HELLO)
        if (hello.stringValue("app") != LanProtocol.APP_TAG) {
            return HelloDecision.Reject(LanProtocol.MSG_INVALID_HELLO)
        }
        val peerId = hello.stringValue("id")?.takeIf { it.isNotBlank() }
            ?: return HelloDecision.Reject(LanProtocol.MSG_INVALID_HELLO)
        if (peerId == selfId) return HelloDecision.Reject(LanProtocol.MSG_INVALID_HELLO)
        val peerName = hello.stringValue("name")?.takeIf { it.isNotBlank() }
            ?: return HelloDecision.Reject(LanProtocol.MSG_INVALID_HELLO)
        if (pairedPeerIds.contains(peerId)) {
            return HelloDecision.Accept(peerId, peerName, alreadyPaired = true)
        }
        val providedCode = hello.stringValue("code")
        if (PairingCode.matches(providedCode, currentCode)) {
            return HelloDecision.Accept(peerId, peerName, alreadyPaired = false)
        }
        return HelloDecision.NeedsPairing(peerId, peerName)
    }
}

/** 客户端收到握手响应后的处理结论。 */
sealed class HandshakeOutcome {

    data class Ok(val peerId: String, val peerName: String) : HandshakeOutcome()

    data class NeedsPairing(val peerName: String) : HandshakeOutcome()

    data class Failure(val message: String) : HandshakeOutcome()
}

object HandshakeInterpreter {

    /** §4.4：解析握手响应（hello_ok / pair_required / error / 未知）。 */
    fun interpret(
        response: Map<String, Any?>?,
        fallbackPeerId: String,
        fallbackPeerName: String,
    ): HandshakeOutcome {
        if (response == null) return HandshakeOutcome.Failure(LanProtocol.MSG_NO_RESPONSE)
        return when (response.stringValue("type")) {
            "hello_ok" -> HandshakeOutcome.Ok(
                peerId = response.stringValue("id")?.takeIf { it.isNotBlank() } ?: fallbackPeerId,
                peerName = response.stringValue("name")?.takeIf { it.isNotBlank() } ?: fallbackPeerName,
            )
            "pair_required" -> HandshakeOutcome.NeedsPairing(
                response.stringValue("name")?.takeIf { it.isNotBlank() } ?: fallbackPeerName,
            )
            "error" -> HandshakeOutcome.Failure(
                response.stringValue("message")?.takeIf { it.isNotBlank() } ?: "对方拒绝了连接",
            )
            else -> HandshakeOutcome.Failure(LanProtocol.MSG_PROTOCOL_MISMATCH)
        }
    }
}
