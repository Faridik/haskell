{-# LANGUAGE OverloadedStrings, QuasiQuotes, TemplateHaskell,
         TypeFamilies, MultiParamTypeClasses, FlexibleContexts, GADTs #-}
import Yesod
import Yesod.Static
import Data.Time (UTCTime)
import System.FilePath
import System.Directory (removeFile, doesFileExist)
import Control.Applicative ((<$>), (<*>))
import Data.Conduit
import Data.Text (unpack)
import qualified Data.ByteString.Lazy as DBL
import Data.Conduit.List (consume)
import Database.Persist
import Database.Persist.Sqlite
import Data.Time (getCurrentTime) 

share [mkPersist sqlSettings,mkMigrate "migrateAll"] [persistUpperCase|
Image
    filename String
    description Textarea Maybe
    date UTCTime
    deriving Show
|]

staticFiles "static"

data App = App 
    { getStatic :: Static -- ^ Settings for static file serving.
    , connPool  :: ConnectionPool
    }

mkYesod "App" [parseRoutes|
/ ImagesR GET POST
/image/#ImageId ImageR DELETE
/static StaticR Static getStatic
|]

instance Yesod App

instance YesodPersist App where
    type YesodPersistBackend App = SqlPersist
    runDB action = do
        App _ pool <- getYesod
        runSqlPool action pool

instance RenderMessage App FormMessage where
    renderMessage _ _ = defaultFormMessage

uploadDirectory :: FilePath
uploadDirectory = "static"

uploadForm :: Html -> MForm App App (FormResult (FileInfo, Maybe Textarea, UTCTime), Widget)
uploadForm = renderBootstrap $ (,,)
    <$> fileAFormReq "Image file"
    <*> aopt textareaField "Image description" Nothing
    <*> aformM (liftIO getCurrentTime)

addStyle :: Widget
addStyle = do
    -- Twitter Bootstrap
    addStylesheetRemote "http://netdna.bootstrapcdn.com/twitter-bootstrap/2.1.0/css/bootstrap-combined.min.css"
    -- message style
    toWidget [lucius|.message { padding: 10px 0; background: #ffffed; } |]
    -- jQuery
    addScriptRemote "http://ajax.googleapis.com/ajax/libs/jquery/1.8.0/jquery.min.js"
    -- delete function
    toWidget [julius|
$(function(){
    function confirmDelete(link) {
        if (confirm("Are you sure you want to delete this image?")) {
            deleteImage(link);
        };
    }
    function deleteImage(link) {
        $.ajax({
            type: "DELETE",
            url: link.attr("data-img-url"),
        }).done(function(msg) {
            var table = link.closest("table");
            link.closest("tr").remove();
            var rowCount = $("td", table).length;
            if (rowCount === 0) {
                table.remove();
            }
        });
    }
    $("a.delete").click(function() {
        confirmDelete($(this));
        return false;
    });
});
|]

getImagesR :: Handler RepHtml
getImagesR = do
    ((_, widget), enctype) <- runFormPost uploadForm
    images <- runDB $ selectList [ImageFilename !=. ""] [Desc ImageDate]
    mmsg <- getMessage
    defaultLayout $ do
        addStyle
        [whamlet|$newline never
$maybe msg <- mmsg
    <div .message>
        <div .container>
            #{msg}
<div .container>
    <div .row>
        <h2>
            Upload new image
        <div .form-actions>
            <form method=post enctype=#{enctype}>
                ^{widget}
                <input .btn type=submit value="Upload">
        $if not $ null images
            <table .table>
                <tr>
                    <th>
                        Image
                    <th>
                        Decription
                    <th>
                        Uploaded
                    <th>
                        Action
                $forall Entity imageId image <- images
                    <tr>
                        <td>
                            <a href=#{imageFilePath $ imageFilename image}>
                                #{imageFilename image}
                        <td>
                            $maybe description <- imageDescription image
                                #{description}
                        <td>
                            #{show $ imageDate image}
                        <td>
                            <a href=# .delete data-img-url=@{ImageR imageId}>
                                delete

|]

postImagesR :: Handler RepHtml
postImagesR = do
    ((result, widget), enctype) <- runFormPost uploadForm
    case result of
        FormSuccess (file, info, date) -> do
            -- TODO: check if image already exists
            -- save to image directory
            filename <- writeToServer file
            _ <- runDB $ insert (Image filename info date)
            setMessage "Image saved"
            redirect ImagesR
        _ -> do
            setMessage "Something went wrong"
            redirect ImagesR

deleteImageR :: ImageId -> Handler ()
deleteImageR imageId = do
    image <- runDB $ get404 imageId
    let filename = imageFilename image
        path = imageFilePath filename
    liftIO $ removeFile path
    -- only delete from database if file has been removed from server
    stillExists <- liftIO $ doesFileExist path

    case (not stillExists) of 
        False  -> redirect ImagesR
        True -> do
            runDB $ delete imageId
            setMessage "Image has been deleted."
            redirect ImagesR

writeToServer :: FileInfo -> Handler FilePath
writeToServer file = do
    let filename = unpack $ fileName file
        path = imageFilePath filename
    liftIO $ fileMove file path
    return filename

imageFilePath :: String -> FilePath
imageFilePath f = uploadDirectory </> f

openConnectionCount :: Int
openConnectionCount = 10

main :: IO ()
main = do
    pool <- createSqlitePool "images.db3" openConnectionCount
    runSqlPool (runMigration migrateAll) pool
    -- Get the static subsite, as well as the settings it is based on
    static@(Static settings) <- static "static"
    warpDebug 3000 $ App static pool
