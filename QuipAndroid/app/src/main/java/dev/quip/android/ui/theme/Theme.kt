package dev.quip.android.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val QuipDarkColorScheme = darkColorScheme(
    primary = AmberPrimary,
    background = DarkBackground,
    surface = DarkSurface,
    onPrimary = DarkBackground,
    onBackground = Color.White,
    onSurface = Color.White,
)

@Composable
fun QuipTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = QuipDarkColorScheme,
        content = content
    )
}
