package app.openfamily.wear.ui

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.background
import androidx.navigation.NavType
import androidx.navigation.navArgument
import androidx.wear.compose.navigation.SwipeDismissableNavHost
import androidx.wear.compose.navigation.composable
import androidx.wear.compose.navigation.rememberSwipeDismissableNavController
import app.openfamily.wear.WearViewModel

@Composable
fun WearApp(vm: WearViewModel, requestLocation: () -> Unit) {
    val nav = rememberSwipeDismissableNavController()
    SwipeDismissableNavHost(navController = nav, startDestination = "home", modifier = Modifier.fillMaxSize().background(Color.Black)) {
        composable("home") { HomeScreen(vm) { nav.navigate(it) } }
        composable("people") { PeopleScreen(vm) { nav.navigate("person/$it") } }
        composable("person/{id}", arguments = listOf(navArgument("id") { type = NavType.StringType })) {
            val id = it.arguments?.getString("id").orEmpty()
            PersonScreen(vm, id) { requestLocation(); nav.navigate("compass/$id") }
        }
        composable("compass/{id}", arguments = listOf(navArgument("id") { type = NavType.StringType })) {
            CompassScreen(vm, it.arguments?.getString("id").orEmpty())
        }
        composable("sos") { SosScreen(vm) }
        composable("checkin") { CheckInScreen(vm) }
        composable("sharing") { SharingScreen(vm) }
        composable("chat") { ChatScreen(vm) }
        composable("alerts") { AlertsScreen(vm) }
    }
}
