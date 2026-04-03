package dev.quip.android.ui.components

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.quip.android.models.WindowState
import dev.quip.android.ui.theme.LocalQuipColors

fun parseHexColor(hex: String): Color {
    val colorInt = android.graphics.Color.parseColor(hex)
    return Color(colorInt)
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun WindowTile(
    window: WindowState,
    isSelected: Boolean,
    isRecording: Boolean,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val colors = LocalQuipColors.current
    val windowColor = parseHexColor(window.color)
    val shape = RoundedCornerShape(8.dp)

    val bgAlpha = if (isSelected) 0.25f else 0.15f
    val borderAlpha = if (isSelected) 1.0f else 0.6f
    val borderWidth = if (isSelected) 2.dp else 1.dp

    // Pulsing animation for waiting_for_input and stt_active states
    val infiniteTransition = rememberInfiniteTransition(label = "pulse")
    val pulseAlpha by infiniteTransition.animateFloat(
        initialValue = 0.3f,
        targetValue = 0.8f,
        animationSpec = infiniteRepeatable(
            animation = tween(
                durationMillis = when (window.state) {
                    "stt_active" -> 500
                    "waiting_for_input" -> 1000
                    else -> 1000
                }
            ),
            repeatMode = RepeatMode.Reverse
        ),
        label = "pulseAlpha"
    )

    val glowColor = when (window.state) {
        "stt_active" -> Color(0xFFD4A017).copy(alpha = pulseAlpha)
        "waiting_for_input" -> windowColor.copy(alpha = pulseAlpha * 0.6f)
        else -> Color.Transparent
    }

    val shadowElevation = when {
        window.state == "stt_active" -> 12.dp
        window.state == "waiting_for_input" -> 8.dp
        isSelected -> 6.dp
        else -> 0.dp
    }

    val shadowColor = when {
        window.state == "stt_active" -> Color(0xFFD4A017)
        window.state == "waiting_for_input" || isSelected -> windowColor
        else -> Color.Transparent
    }

    Box(
        modifier = modifier
            .shadow(
                elevation = shadowElevation,
                shape = shape,
                ambientColor = shadowColor,
                spotColor = shadowColor
            )
            .clip(shape)
            .background(windowColor.copy(alpha = bgAlpha))
            .border(borderWidth, windowColor.copy(alpha = borderAlpha), shape)
            .combinedClickable(
                onClick = onClick,
                onLongClick = onLongClick
            )
    ) {
        // Pulsing glow overlay for active states
        if (window.state == "stt_active" || window.state == "waiting_for_input") {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(glowColor, shape)
            )
        }

        // Content labels
        Column(
            modifier = Modifier
                .align(Alignment.TopStart)
                .padding(10.dp)
        ) {
            Text(
                text = window.name,
                color = colors.textPrimary.copy(alpha = 0.9f),
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1
            )
            Text(
                text = window.app,
                color = colors.textSecondary.copy(alpha = 0.7f),
                fontSize = 9.sp,
                maxLines = 1
            )
        }

        // Disabled overlay
        if (!window.enabled) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.5f), shape),
                contentAlignment = Alignment.Center
            ) {
                // Use a text stand-in for eye-slash since we don't have the icon resource
                Text(
                    text = "\u00D8", // slashed circle as stand-in
                    color = colors.textTertiary,
                    fontSize = 18.sp
                )
            }
        }
    }
}
