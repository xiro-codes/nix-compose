use rocket::{Build, Rocket, get, launch, routes};

#[get("/")]
async fn hello_world() -> String {
    "Hello World".to_string()
}
#[launch]
async fn rocket() -> Rocket<Build> {
    Rocket::build().mount("/", routes![hello_world])
}
